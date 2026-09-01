# PR #1169 — radvd

<https://github.com/canonical/chisel-releases/pull/1169>

分支 `feat-26.04-radvd`，目标分支 `ubuntu-26.04`。

## 1. 这个包是干什么的

### 先讲 IPv6 的地址自动配置

IPv4 里主机拿地址靠 DHCP：客户端广播请求，DHCP 服务器分配一个地址给它。

IPv6 有一套不同的机制叫 **SLAAC**（Stateless Address Autoconfiguration，
无状态地址自动配置）—— **不需要**服务器维护地址池和租约表：

1. 路由器周期性地在链路上多播 **RA**（Router Advertisement，路由器通告）报文，
   里面说"我这条链路的网络前缀是 `2001:db8:1::/64`，我是默认网关，
   MTU 是 1500，DNS 服务器是 xxx"
2. 主机收到 RA，取出 64 位前缀，自己拼上 64 位接口标识（用 MAC 地址算出来，
   或者随机生成保护隐私），得到完整的 128 位地址
3. 主机做一次 **DAD**（Duplicate Address Detection）确认没人用这个地址，
   就直接开始用

主机也可以主动发 **RS**（Router Solicitation）催路由器立刻回一个 RA，
不用等下一个周期。

RA / RS 都是 **ICMPv6** 报文（类型 134 / 133），走链路本地多播，不经过路由器。

### `radvd` 就是发 RA 的那个守护进程

**R**outer **ADV**ertisement **D**aemon。在 Linux 上把一台机器变成 IPv6 路由器时，
内核负责转发，`radvd` 负责发 RA 告诉链路上的主机该怎么配地址。

典型场景：
- 家用/企业 IPv6 网关
- 容器/虚拟机宿主机给自己的桥接网络发 RA
- 网络设备（交换机、路由器）的 IPv6 控制面

配置文件 `/etc/radvd.conf` 长这样：

```
interface eth0
{
    AdvSendAdvert on;              # 主动周期性发 RA（不只是被动回 RS）
    MinRtrAdvInterval 30;          # 相邻两个 RA 之间最短 30 秒
    MaxRtrAdvInterval 100;         # 最长 100 秒
    prefix 2001:db8:dead:beef::/64
    {
        AdvOnLink on;              # 这个前缀在本链路上（不用经路由器）
        AdvAutonomous on;          # 允许主机用它做 SLAAC
        AdvRouterAddr on;          # RA 里带上路由器自己的完整地址
    };
    RDNSS 2001:db8:dead:beef::1    # 通过 RA 下发 DNS 服务器（RFC 8106）
    {
        AdvRDNSSLifetime 300;
    };
};
```

实现上 radvd 只依赖 `libc6`，通过原始 ICMPv6 socket 收发报文，
并读 `/proc/sys/net/ipv6/*` 检查转发是否打开、MTU 是多少。
它还做**特权分离**：主进程 fork 出一个非特权子进程处理报文，
父进程保留发包权限（日志里能看到 `privsep_read_loop`）。

## 2. 切片设计

```yaml
package: radvd

essential:
  radvd_copyright:

slices:
  # The adduser dependency is only used by the postinst, to create the "radvd"
  # system user for the optional --username option; maintainer scripts are
  # handled differently in Chisel. /etc/init.d/radvd is left out as well: the
  # systemd unit below supersedes it.
  bins:
    hint: IPv6 router advertisement daemon
    essential:
      libc6_libs:
    contents:
      /usr/sbin/radvd:

  services:
    essential:
      radvd_bins:
    contents:
      # The unit has ConditionPathExists=/etc/radvd.conf. The deb ships no
      # default config -- only examples under /usr/share/doc -- so the
      # configuration stays up to the consumer.
      /usr/lib/systemd/system/radvd.service:

  copyright:
    contents:
      /usr/share/doc/radvd/copyright:
```

### deb 里有什么

```
/etc/init.d/radvd                              ✗ 丢弃（sysvinit）
/usr/lib/systemd/system/radvd.service          → services
/usr/sbin/radvd                                → bins
/usr/share/doc/radvd/INTRO.html                ✗ 文档
/usr/share/doc/radvd/copyright                 → copyright
/usr/share/doc/radvd/examples/radvd.conf.example   ✗ 示例（在 doc 下）
/usr/share/doc/radvd/examples/simple-radvd.conf    ✗ 示例
/usr/share/man/**                              ✗ 手册
```

### 为什么没有 `config` 切片

这是这个包最值得说的一点：**deb 根本不提供 `/etc/radvd.conf`**。

原因很好理解 —— RA 的内容（网络前缀、接口名、DNS 地址）完全取决于具体部署，
没有任何有意义的默认值。Debian 只在 `/usr/share/doc/radvd/examples/` 下放了
两个示例文件供参考。

systemd unit 也明确体现了这个设计：

```ini
ConditionPathExists=/etc/radvd.conf
```

**没有配置文件时服务直接跳过启动**（而不是启动失败），这是 systemd 的
condition 语义。

所以我没有 `config` 切片可切 —— 配置由使用者提供。示例文件在
`/usr/share/doc/` 下，按约定属于文档，不切。我把这一点写进了 SDF 注释和 PR 描述，
避免 reviewer 问"为什么没有 config"。

### `Depends: adduser` 为什么没有对应 essential

postinst 里：

```sh
if ! getent passwd radvd >/dev/null; then
  adduser --quiet --system --no-create-home --home /run/radvd radvd
fi
```

建一个 `radvd` 系统用户。这个用户是给 `radvd -u radvd` / `--username` 选项用的
—— **可选功能**，不是默认行为。

而 Debian 的 systemd unit 根本没用 `-u`，它用的是更现代的 systemd 沙箱化：

```ini
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=full
ProtectHome=yes
NoNewPrivileges=yes
```

所以 `adduser` 是纯 maintainer-script 依赖，运行时不需要。我在 SDF 里写了注释
解释（CI 的 `pkg-deps` 会把这个差异贴到 PR 评论，注释能让 reviewer 直接理解）。

这和 `libibverbs1`（postinst 建 `rdma` 组）、`iproute2`（debconf）是同一类处理。

### 丢弃 `/etc/init.d/radvd`

sysvinit 脚本，被 unit 取代。同 smartmontools / ipmitool 的处理。

## 3. spread 测试逐行解释

文件：`tests/spread/integration/radvd/task.yaml`

这个测试是这批包里**唯一真正把守护进程跑起来**的（其他守护进程要么需要硬件，
要么需要外部服务）。radvd 只需要一张网卡和 ICMPv6 socket，容器里就能满足。

```bash
rootfs="$(install-slices radvd_bins)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"
chmod 666 "${rootfs}/dev/null"
```
radvd 后台化（daemonize）时要把 stdin/stdout/stderr 重定向到 `/dev/null`，
所以必须造一个，而且要可写（`chmod 666`）。

```bash
cleanup() {
  if [ -f "${rootfs}/radvd.pid" ]; then
    kill -TERM "$(cat "${rootfs}/radvd.pid")" 2>/dev/null || true
  fi
  umount -l "${rootfs}/proc" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "${rootfs}/proc"
mount -t proc proc "${rootfs}/proc"
```
两件事：

1. **兜底清理**。守护进程是 rootfs 外的内核对象，测试中途失败必须杀掉它，
   否则会残留在同一容器里污染后续任务；bind mount 的 `/proc` 也必须卸载，
   否则 rootfs 目录删不掉。
2. **挂 procfs**。radvd 要读
   `/proc/sys/net/ipv6/conf/<iface>/forwarding`、`.../mtu`、
   `/proc/sys/net/ipv6/neigh/<iface>/retrans_time_ms` 等。不挂的话日志里会刷一串
   `Correct IPv6 forwarding procfs entry not found, perhaps the procfs is
   disabled...` 警告（radvd 会容错继续跑，但那样就没验证到这段代码）。

```bash
rc=0
out="$(chroot "${rootfs}" /usr/sbin/radvd --version 2>&1)" || rc=$?
test "${rc}" -eq 1
echo "${out}" | grep -Fq "Version: 2.20"
echo "${out}" | grep -Fq '"/etc/radvd.conf"'
echo "${out}" | grep -Fq '"/run/radvd.pid"'
```
**这里有一个我实际踩到的坑，值得单独讲。**

`radvd --version` 和 `--help` 的**退出码是 1，不是 0**（radvd 把它们都走
`usage()` 路径，最后 `exit(1)`）。

我最初写的是 `out="$(chroot ... --version 2>&1)"`，没有接住退出码。
`set -e` 下命令替换赋值失败会直接终止脚本，于是测试在第一条断言之前就挂了。
spread 的 `set -x` 日志显示 `out=$'Version: 2.20...'` 之后直接跳到 `cleanup`，
后面的 `echo`/`grep` 一行都没执行 —— 就是这个原因。

我之前在虚拟机上手工探测时写的是
`radvd --version 2>&1 | head -8; echo "rc=$?"`，这里的 `$?` 是 `head` 的退出码
（0），把真实退出码掩盖了。所以本地探测也要小心管道。

修好之后我**显式断言 `test "${rc}" -eq 1`** —— 不是简单 `|| true` 敷衍过去，
而是把这个行为记录下来。将来 radvd 改成 exit 0 了，测试会失败并提醒我们。

三条内容断言：版本号、以及编译进去的两个默认路径。后两条不是凑数 ——
systemd unit 依赖这两个默认值（unit 里的 `PIDFile=/run/radvd.pid` 必须和
radvd 编译时的默认一致，`ConditionPathExists=/etc/radvd.conf` 同理）。
断言它们等于在验证 unit 和二进制是配套的。

```bash
rc=0
out="$(chroot "${rootfs}" /usr/sbin/radvd --help 2>&1)" || rc=$?
test "${rc}" -eq 1
echo "${out}" | grep -Fq "usage: radvd"
echo "${out}" | grep -Fq -- "--configtest"
```
**第二个坑**：`grep -Fq "--configtest"` 会被 grep 当成选项解析，
报 `grep: unrecognized option '--configtest'`。必须加 `--` 分隔符：
`grep -Fq -- "--configtest"`。

```bash
iface="$(ip -4 route show default | awk '{print $5; exit}')"
test -n "${iface}"
{
  echo "interface ${iface}"
  echo "{"
  echo "    AdvSendAdvert on;"
  ...
} > "${rootfs}/radvd.conf"
```
生成配置文件，接口名从容器的路由表里取（LXD 容器里是 `eth0`）。

用**真实存在的接口**很重要：`--configtest` 不检查接口是否存在，但真的跑起来
之后 radvd 要打开这个接口的 socket、读它的 procfs 项、往它上面发 RA。
接口不存在的话 radvd 会一直报错重试，后面的断言就没意义了。

用 `{ echo; echo; } > file` 而不是 heredoc —— YAML 的 `execute: |` 块靠缩进
界定，heredoc 的内容和结束符必须顶格，而顶格会提前终止 YAML 块。
（这个坑我在 pciutils 上踩过一次了。）

配置里我特意放了 `prefix` 和 `RDNSS` 两个子块，覆盖 radvd 配置解析器的
两类嵌套语法。

```bash
out="$(chroot "${rootfs}" /usr/sbin/radvd --configtest \
  --config /radvd.conf --logmethod stderr_clean 2>&1)"
echo "${out}" | grep -Fq "syntax ok"
```
**`--configtest` 是 radvd 最好的"离线可测"入口**：它把配置文件完整解析一遍
（走 lex/yacc 生成的解析器）然后退出，不碰网络、不需要权限，
退出码 0，输出 `config file, /radvd.conf, syntax ok`。

```bash
printf 'interface eth0 {\n  AdvSendAdvert bogusvalue;\n};\n' \
  > "${rootfs}/broken.conf"
rc=0
out="$(chroot "${rootfs}" /usr/sbin/radvd --configtest \
  --config /broken.conf --logmethod stderr_clean 2>&1)" || rc=$?
test "${rc}" -ne 0
echo "${out}" | grep -Fq "/broken.conf:2 error: syntax error"
echo "${out}" | grep -Fiq "failed to read config file"
```
**负向测试**。`AdvSendAdvert` 只接受 `on`/`off`，给它 `bogusvalue` 会触发语法错误。

断言两件事：退出码非 0，以及错误信息**带正确的行号**（`:2`）。
断言行号是关键 —— 它证明解析器真的在逐行解析，而不是笼统地拒绝了整个文件。

有了这条负向测试，上面那条 `syntax ok` 才有意义（否则一个"永远说 ok"的
假实现也能通过）。

```bash
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
```
打开 IPv6 转发。radvd 检测到转发关闭时只是警告
（`IPv6 forwarding seems to be disabled, but continuing anyway`）并继续，
所以这一步是 **best-effort**（`|| true`），后面的断言不依赖它。

这么写是为了兼容 CI 的 docker backend —— 那里可能禁用了 IPv6 或者
`/proc/sys/net/ipv6` 不可写。

```bash
chroot "${rootfs}" /usr/sbin/radvd --config /radvd.conf --debug 2 \
  --logmethod logfile --logfile /radvd.log --pidfile /radvd.pid
```
**真的启动守护进程**。四个参数：

- `--config /radvd.conf` 用刚生成的配置
- `--debug 2` 二级调试输出 —— **这个是必须的**，见下面的说明
- `--logmethod logfile --logfile /radvd.log` 日志写到 rootfs 里的文件，
  这样测试可以从外面读它（默认是写 syslog，容器里读不到）
- `--pidfile /radvd.pid` 同理，写到 rootfs 里

**关于 `--debug 2`**：我第一版没加，结果日志里只有一行
`version 2.20 started`，而我断言的 `config file, ..., syntax ok` 一直等不到，
5 秒轮询超时后失败。

调查发现：radvd 后台化之后，`syntax ok` 和 interface 轮询这些信息属于
**debug 级别**的日志，默认不写。加上 `--debug 2` 之后日志变成：

```
[...] radvd (446155): version 2.20 started
[...] radvd (446155): config file, /radvd.conf, syntax ok
[...] radvd (446156): polling for 16 second(s), next iface is eth0
```

第三行尤其有价值 —— 它证明 radvd 已经**认领了配置里的那个接口并开始服务它**，
这比"进程还活着"强得多。

```bash
for _ in $(seq 50); do
  [ -s "${rootfs}/radvd.pid" ] && break
  sleep 0.1
done
test -s "${rootfs}/radvd.pid"
pid="$(cat "${rootfs}/radvd.pid")"
```
**有界等待** pidfile 出现：最多 50 次 × 0.1 秒 = 5 秒。
mason 明确禁止裸 `sleep` 和无界重试循环 —— 前者浪费时间且不可靠，
后者会让 spread 挂死。

循环退出后仍然 `test -s` 一次，这样超时的情况会明确失败而不是悄悄往下走。

```bash
kill -0 "${pid}"
```
`kill -0` 不发信号，只检查进程存在。确认守护进程真的在跑（而不是启动后立刻崩了
但 pidfile 还留着）。

```bash
for _ in $(seq 50); do
  grep -Fq "next iface is ${iface}" "${rootfs}/radvd.log" && break
  sleep 0.1
done
grep -Fq "version 2.20 started" "${rootfs}/radvd.log"
grep -Fq "config file, /radvd.conf, syntax ok" "${rootfs}/radvd.log"
grep -Fq "next iface is ${iface}" "${rootfs}/radvd.log"
```
有界等待日志出现，然后三条断言：

1. `version 2.20 started` —— 主进程启动
2. `config file, /radvd.conf, syntax ok` —— 用的是我给的配置文件（路径也断言了）
3. `next iface is eth0` —— **最强的一条**：radvd 认领了配置里声明的接口
   并进入了发 RA 的轮询循环

第三条把接口名插值进断言（`${iface}`），所以它同时验证了配置解析
→ 接口查找 → 轮询调度这整条链路。

```bash
kill -TERM "${pid}"
for _ in $(seq 50); do
  [ -e "${rootfs}/radvd.pid" ] || break
  sleep 0.1
done
! test -e "${rootfs}/radvd.pid"
grep -Fq "sending stop adverts" "${rootfs}/radvd.log"
```
**优雅关闭测试**。这不只是"能停"，而是验证 radvd 的正确退出协议：

- `sending stop adverts` —— radvd 在退出前会发一批
  **router lifetime = 0** 的 RA，通知链路上所有主机"我不再是路由器了，
  别再用我做网关"。少了这一步，主机会继续往一个已经消失的网关发包，
  直到 RA 生命周期自然过期（可能几十分钟）。这是 radvd 一个重要的正确性行为。
- pidfile 被删除 —— 证明它清理了自己的状态文件。

```bash
sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
```
恢复转发设置。spread 容器是一次性的，但同一个容器会跑多个 task，
不留下副作用是好习惯。

```bash
rootfs="$(install-slices radvd_services)"
unit="${rootfs}/usr/lib/systemd/system/radvd.service"
grep -Fq "ExecStart=/usr/sbin/radvd" "${unit}"
grep -Fq "ConditionPathExists=/etc/radvd.conf" "${unit}"
grep -Fq "PIDFile=/run/radvd.pid" "${unit}"
test -x "${rootfs}/usr/sbin/radvd"
```
**`services` 切片的引用完整性检查**（换新 rootfs，只装 services）。

不在容器里真的 `systemctl start` —— unit 里有
`ConditionVirtualization=no`，在容器里 systemd 会直接跳过它；而且往容器的
systemd 里注册服务会污染环境。

所以做的是静态一致性检查：

1. `ExecStart` 指向的二进制在 rootfs 里存在且可执行 —— 验证
   `essential: radvd_bins` 写对了
2. `ConditionPathExists` 和 `PIDFile` 两个路径，和前面 `--version` 输出里
   断言的编译时默认值**完全一致** —— 验证 unit 和二进制是配套的
