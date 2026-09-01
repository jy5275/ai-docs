# PR #1163 — bridge-utils

<https://github.com/canonical/chisel-releases/pull/1163>

分支 `feat-26.04-bridge-utils`，目标分支 `ubuntu-26.04`。

## 1. 这个包是干什么的

`bridge-utils` 提供 **`brctl`** —— Linux 内核以太网网桥的管理工具。

Linux 内核可以把若干张网卡"焊"成一个二层交换机，这个虚拟交换机就叫 bridge。
容器、虚拟机的网络基本都靠它：`docker0`、`lxdbr0`、`virbr0` 全是 bridge。

`brctl` 就是操作它的命令行：

| 命令 | 作用 |
|---|---|
| `brctl addbr br0` | 创建网桥 `br0` |
| `brctl delbr br0` | 删除网桥 |
| `brctl addif br0 eth1` | 把 `eth1` 插到网桥上（相当于插网线） |
| `brctl delif br0 eth1` | 拔掉 |
| `brctl show` | 列出所有网桥和它们的端口 |
| `brctl showmacs br0` | 看网桥的 MAC 地址转发表（就是交换机的 CAM 表） |
| `brctl showstp br0` | 看生成树协议状态 |
| `brctl stp br0 on` | 开关 STP（防环路） |
| `brctl setageing br0 120` | 设置 MAC 表项老化时间 |
| `brctl setbridgeprio br0 4096` | 设置网桥优先级（STP 选根桥用） |

严格来说 `brctl` 已经被 `ip link` / `bridge`（iproute2）取代了，但大量运维脚本、
网络设备的固件（比如 SONiC）还在用它，所以还是要有。

实现上它非常轻：只依赖 `libc6`，所有操作走 ioctl 和读 `/sys/class/net/`。

## 2. 切片设计

最终只有两个切片：

```yaml
package: bridge-utils

essential:
  bridge-utils_copyright:

slices:
  bins:
    hint: Ethernet bridge administration
    essential:
      libc6_libs:
    contents:
      /usr/sbin/brctl:

  copyright:
    contents:
      /usr/share/doc/bridge-utils/copyright:
```

### deb 里到底有什么

```
/etc/default/bridge-utils                              配置片段
/etc/network/if-down.d/bridge       -> ifupdown.sh     ifupdown 钩子
/etc/network/if-post-down.d/bridge  -> ifupdown.sh     ifupdown 钩子
/etc/network/if-pre-up.d/bridge     -> ifupdown.sh     ifupdown 钩子
/usr/lib/bridge-utils/bridge-utils.sh                  shell 函数库
/usr/lib/bridge-utils/ifupdown.sh                     ifupdown 钩子实现
/usr/lib/udev/bridge-network-interface                 udev 热插拔脚本
/usr/lib/udev/rules.d/60-bridge-network-interface.rules udev 规则
/usr/sbin/brctl                                        ★ 主程序
/usr/share/doc/bridge-utils/*                          文档
/usr/share/man/*                                       手册
```

### 为什么只留了 brctl

**扔掉 ifupdown 钩子那一套**（`/etc/network/if-*.d/bridge`、`ifupdown.sh`、
`bridge-utils.sh`）：我读了 `ifupdown.sh` 的源码，它里面调 `ifquery`，
而 `ifquery` 属于 `ifupdown` 包 —— chisel-releases 里根本没有 `ifupdown`。
这些钩子只有在 ifupdown 驱动网络时才会被触发，装进来是死重量。

**扔掉 udev 那一套**：`/usr/lib/udev/bridge-network-interface` 需要两个前提，
一是有 udevd 在跑来触发规则，二是脚本本体也调 `ifquery`。我确认过
chisel-releases 26.04 里既没有 `udev` 包，也没有任何切片提供 `udevd`/`udevadm`
二进制（`systemd.yaml` 只有一个 `udev-rules` 切片放了四个 systemd 自己的规则文件，
没有守护进程）。所以同样是死重量。

**扔掉 `/etc/default/bridge-utils`**：我 `strings` 过 `brctl` 二进制，它只引用
`/sys/class/net/*`，完全不读这个配置文件。真正读它的是上面那两套被扔掉的脚本
（`[ -f /etc/default/bridge-utils ] && . /etc/default/bridge-utils`）。既然消费者
都没了，配置文件也就没意义了 —— mason 的 review 准则里有一条正是
"不要为没被切片的工具提供配置文件"。

这几个判断我都写在 SDF 的注释和 PR 描述里了，方便 reviewer 复核。将来要是有人
把 `ifupdown` 切了，可以再补一个 `scripts` / `rules` 切片 —— chisel-releases 是
**只增不删**的，新增切片没问题，从已发布切片里删路径才是禁忌。

### maintainer script

`postinst` 只有 `db_purge`（清 debconf 状态），对 rootfs 没有任何影响，不需要复现。

### 依赖

`Depends: libc6 (>= 2.38)`，就这一个，而且已经切好了。所以这个 PR 只有一个新
SDF，不需要先切依赖。

## 3. spread 测试逐行解释

文件：`tests/spread/integration/bridge-utils/task.yaml`

```bash
rootfs="$(install-slices bridge-utils_bins)"
```
切一个只装 `bridge-utils_bins` 的 rootfs（helper 会自动追加 `base-files_chisel`
生成 manifest）。因为 `bins` 的 essential 只写了 `libc6_libs`，如果我漏了依赖，
这里 chroot 就会因为找不到动态库而失败 —— 这就是"独立 rootfs"的意义。

```bash
cleanup() {
  chroot "${rootfs}" /usr/sbin/brctl delbr chisel-br0 2>/dev/null || true
  umount -l "${rootfs}/sys" 2>/dev/null || true
}
trap cleanup EXIT
```
兜底清理。测试中途失败也要保证：① 建出来的网桥被删掉（它是内核对象，不在
rootfs 里，spread 清 rootfs 清不掉它，会污染同一容器里的后续任务）；
② bind mount 的 `/sys` 被卸载（不卸载会导致 rootfs 目录删不掉）。

```bash
chroot "${rootfs}" /usr/sbin/brctl --version | grep -Fiq "bridge-utils"
```
最基本的冒烟：进程能起来、动态链接器能解析 `libc.so.6`、程序自报版本
（输出 `bridge-utils, 1.7`）。这一步不碰内核。

这里用管道是安全的，因为 `--version` 只输出一行，写完就退出了，不会被 SIGPIPE
打断。

```bash
out="$(chroot "${rootfs}" /usr/sbin/brctl 2>&1 || true)"
echo "${out}" | grep -Fiq "usage: brctl"
```
不带参数运行 `brctl` 会打印用法然后**返回 1**，所以要 `|| true` 兜住，
否则 `set -e` 会直接终止测试。用 `2>&1` 因为用法输出在 stderr。

```bash
mkdir -p "${rootfs}/sys"
mount --bind /sys /sys
```
（实际代码是 `mount --bind /sys "${rootfs}/sys"`。）`brctl show` / `showstp` /
`showmacs` 都是读 `/sys/class/net/` 来枚举网桥的，chroot 里没有挂 sysfs 就什么都
看不到。所以从容器把 `/sys` bind 进去。

```bash
chroot "${rootfs}" /usr/sbin/brctl show >/dev/null
```
先验证"网桥列表为空时也能正常返回"。

这里有个坑值得记一下：我最初写的是
`brctl show | grep -Fiq "bridge name"`，断言表头。结果在 LXD 容器里一直失败。
调试发现 **bridge-utils 1.7 的 `brctl show` 在一个网桥都没有时不打印表头，
输出完全为空**。我在虚拟机上测是通的，因为虚拟机上有 `lxdbr0`。所以表头断言
必须挪到建完网桥之后。

```bash
chroot "${rootfs}" /usr/sbin/brctl addbr chisel-br0
out="$(chroot "${rootfs}" /usr/sbin/brctl show)"
echo "${out}" | grep -Fiq "bridge name"
echo "${out}" | grep -Fq "chisel-br0"
```
**真正创建一个内核网桥**（`SIOCBRADDBR` ioctl），然后确认 `show` 能列出它。
到这一步已经证明 `brctl` 不只是能启动，而是真的在操作内核。

在非特权 LXD 容器里 root 对自己的 network namespace 有 `CAP_NET_ADMIN`，
所以建网桥是允许的。

```bash
chroot "${rootfs}" /usr/sbin/brctl stp chisel-br0 on
chroot "${rootfs}" /usr/sbin/brctl setageing chisel-br0 120
chroot "${rootfs}" /usr/sbin/brctl setbridgeprio chisel-br0 4096
```
三个不同的写操作，覆盖 `brctl` 的三类 setter：开关 STP、设时间参数、设优先级。

```bash
out="$(chroot "${rootfs}" /usr/sbin/brctl showstp chisel-br0)"
echo "${out}" | grep -Eq "ageing time[[:space:]]+120\.00"
echo "${out}" | grep -Eq "bridge id[[:space:]]+1000\."
```
**把刚写进去的值读回来核对**，这才叫功能测试而不是"命令返回 0 就算过"：

- `ageing time 120.00` —— 对应上面的 `setageing 120`（内核里存的是 12000
  个 jiffies，`showstp` 换算成秒显示）。
- `bridge id 1000.xxxx` —— 网桥 ID 的前两字节就是优先级，`4096` = `0x1000`，
  所以显示成 `1000.`。这一条同时验证了 `setbridgeprio` 生效。

用 `grep -E` + `[[:space:]]+` 是因为 `showstp` 用制表符和空格混合对齐，
写死空格数会脆。

```bash
out="$(chroot "${rootfs}" /usr/sbin/brctl showmacs chisel-br0)"
echo "${out}" | grep -Fiq "port no"
```
`showmacs` 读 `/sys/class/net/br0/brforward`，验证 MAC 转发表查询路径通。
新建的网桥没有端口所以表是空的，但表头 `port no  mac addr ...` 会打印。

```bash
chroot "${rootfs}" /usr/sbin/brctl delbr chisel-br0
out="$(chroot "${rootfs}" /usr/sbin/brctl show)"
! echo "${out}" | grep -Fq "chisel-br0"
```
删掉网桥，并**反向断言**它确实不在列表里了。走完"建 → 配 → 读 → 删"完整生命周期。

### 为什么没测 `addif` / `delif`

给网桥插端口需要先有一张空闲网卡。容器里只有 `eth0`（正在用，插上去会断网）和
`lo`（不能插网桥）。造一个 dummy 网卡需要宿主机加载 `dummy` 内核模块，非特权
容器里不能自动加载，在 CI 的 6 个架构上不可靠。权衡之后放弃 —— `brctl` 是单个
二进制，覆盖率要求已经满足（`check-test.py` 报 `binaries all exercised`），
剩下两个子命令走的是和 `addbr` 完全相同的 ioctl 通路。
