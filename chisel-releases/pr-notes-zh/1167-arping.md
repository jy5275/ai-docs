# PR #1167 — arping + libnet9 + libpcap0.8t64 + libibverbs1

<https://github.com/canonical/chisel-releases/pull/1167>

分支 `feat-26.04-arping`，目标分支 `ubuntu-26.04`。

`libpcap0.8t64` 和 `libibverbs1` 与 PR #1166（tcpdump）共享，那两个包的说明和
测试解释见 [1166-tcpdump.md](1166-tcpdump.md)，这里只讲 `arping` 和 `libnet9`。

## 1. 这几个包是干什么的

### `arping` —— 二层的 ping

普通 `ping` 走 ICMP，是三层（IP 层）的。`arping` 走 **ARP**，是二层的：

```bash
arping -c 3 192.168.1.1        # 向这个 IP 发 ARP 请求，看谁回应
arping -r -c 1 192.168.1.1     # 只输出解析到的 MAC 地址
arping -c 1 00:11:22:33:44:55  # 反过来：给 MAC 发，问它的 IP
```

为什么需要它：

- **对方防火墙封了 ICMP** 时，ARP 照样能探到，因为 ARP 是二层协议，
  网络栈必须回应（不回应就没法通信）。
- **检测 IP 冲突**：发 ARP 请求问某个 IP，如果收到多个不同 MAC 的回应，
  说明有两台机器抢同一个 IP。
- **确认对方真的在同一广播域**：ARP 不经过路由器，能通就说明在同一个二层网络。
- **唤醒/刷新邻居表**。

注意 Ubuntu 里有两个不同的 `arping`：`iputils-arping`（iputils 那套）和这个独立的
`arping` 包（Thomas Habets 写的，版本 2.x）。我切的是后者，功能更全
（支持按 MAC 反查、VLAN 标签、指定优先级等）。

它的实现比较有意思，有三层依赖：

- **`libnet`** 用来**构造并发送**原始 ARP 帧
- **`libpcap`** 用来**抓取**回应的帧
- **`libseccomp`** 用来自我沙箱化

而且它安全设计做得比较激进：打开原始 socket 之后立刻
**降权到 `nobody` 用户 + chroot + 启用 Landlock + 上 seccomp 过滤器**。
这直接影响了切片设计（见下）。

### `libnet9` —— 原始报文构造库

`libnet.so.9`。提供一套 API 让程序**手工拼装任意网络协议报文**并从链路层发出去：
以太网头、ARP、IP、TCP、UDP、ICMP…… 你想发一个 TTL=1、校验和故意算错的
畸形包，用它就行。

`libpcap` 是"读"，`libnet` 是"写"，很多网络工具两个一起用。
它只依赖 `libc6`。

包名从 `libnet1` 变成了 `libnet9` —— 这是 soname 大版本跳变（Debian 的
`libnet` 上游把 soname 从 1 直接跳到 9 对齐了版本号）。

## 2. 切片设计

### 依赖顺序

```
libnl-3-200 / libnl-route-3-200（已切好）
        │
        ▼
   libibverbs1 ──┐
                 ├──► libpcap0.8t64 ──┐
   libdbus-1-3 ──┘                    │
   （已切好）                          ├──► arping
                       libnet9  ───────┤
                       libseccomp2 ────┘
                       （已切好）
```

### `libnet9.yaml` —— 从 24.04 的 `libnet1` 沿用结构

按 mason 的流程，写新 SDF 前要先查这个包在**其他 release 分支**上有没有已有的
SDF，有的话尽量沿用结构（forward-port 时 reviewer 好对比）。

我查到 `libnet1.yaml` 在 `ubuntu-24.04` 和 `ubuntu-25.10` 上都有：

```yaml
package: libnet1

essential:
  - libnet1_copyright          # 注意：列表形式（v1/v2 分支）

slices:
  libs:
    essential:
      - libc6_libs
    contents:
      /usr/lib/*-linux-*/libnet.so.1*:

  copyright:
    contents:
      /usr/share/doc/libnet1/copyright:
```

我的 26.04 版本结构完全一致，只做了必要的适配：

```yaml
package: libnet9

essential:
  libnet9_copyright:           # v3 必须是 map 形式

slices:
  libs:
    hint: Low level packet construction library   # v3 才支持 hint
    essential:
      libc6_libs:
    contents:
      /usr/lib/*-linux-*/libnet.so.9*:            # soname 1 -> 9

  copyright:
    contents:
      /usr/share/doc/libnet9/copyright:
```

三处差异都是被迫的：
1. `essential:` 从列表变 map —— v3 分支上列表形式会被 chisel 报
   `essential expects a map` 解析失败；
2. 加了 `hint:` —— v3 新特性，老分支不支持所以那边没有；
3. soname 从 `1*` 变 `9*`，包名和 copyright 路径跟着变。

这属于 mason 说的"forward-port 是适配，不是复制粘贴"。

### `arping.yaml`

```yaml
package: arping

essential:
  arping_copyright:

slices:
  # /usr/include/arping.h ships in the runtime deb (there is no -dev package)
  # but there is no library to build against, so it is left out.
  bins:
    hint: ARP level ping utility
    essential:
      libc6_libs:
      libnet9_libs:
      libpcap0.8t64_libs:
      libseccomp2_libs:
    contents:
      # arping drops privileges to "nobody" and chroots before sending, so a
      # rootfs also needs base-passwd_data for the passwd entry.
      /usr/sbin/arping:

  copyright:
    contents:
      /usr/share/doc/arping/copyright:
```

#### 关于降权到 `nobody`

`objdump`/`strings` 显示 arping 里有 `getpwnam`、`chroot`、
`arping: getpwnam(%s): unknown user` 这些符号和字符串。实测确认它启动后会：

```
arping: Landlock enabled
This box:   Interface: enp0s1  IP: 192.168.2.3   MAC address: 52:54:00:60:be:4c
```

然后降权到 `nobody` 再发包。

和 tcpdump 的 `tcpdump` 用户不同，**`nobody` 是 Debian 基础用户，
`base-passwd` 里就有**，所以不需要额外的 sysusers 切片。我在 `contents:` 上加了
注释提醒使用者：rootfs 里得有 `base-passwd_data`（测试里也是这么装的）。

要不要把 `base-passwd_data` 写进 `bins` 的 essential？我没写。理由：
`base-passwd` 不在 arping 的 `Depends:` 里（Debian 里它是 `Essential: yes`），
而 CI 的 `pkg-deps` 会把 SDF 的 essential 和 deb 的 `Depends:` 做 diff，
多写会产生噪音。而且几乎所有实际镜像都会带 `base-passwd`。折中方案是写注释说清楚。

#### 丢弃 `/usr/include/arping.h`

这个 deb 里居然有个头文件 —— 因为 arping 上游的 `make install` 会装它，
而 Debian 没给它单独开 `-dev` 包。但：

1. arping 不提供任何共享库，头文件没有可链接的对象；
2. 头文件是运行时完全不需要的。

按约定头文件该放 `headers` 切片，但为一个没用的头文件开一个切片属于
mason 明确反对的"投机性切片"。所以丢弃 + 注释说明。

#### 共享包的字节级一致

`libpcap0.8t64.yaml`、`libibverbs1.yaml` 和它们的 task.yaml 在这个分支和
tcpdump 分支上是**完全相同的文件**。提交前我用 diff 逐个核对过：

```bash
for f in slices/libpcap0.8t64.yaml slices/libibverbs1.yaml \
         tests/spread/integration/libpcap0.8t64/task.yaml \
         tests/spread/integration/libibverbs1/task.yaml; do
  diff <(git -C ../tcpdump show feat-26.04-tcpdump:"$f") "$f" && echo "identical: $f"
done
```

这样不论哪个 PR 先合，另一个都能干净合入 —— git 对"两边新增同名文件且内容相同"
的情况可以自动消解，不会产生冲突。

这个约束也决定了那两个库的测试**不能用消费者来验证**（一边只有 tcpdump，
一边只有 arping），改成了用动态链接器验证依赖闭包。详见
[1166-tcpdump.md](1166-tcpdump.md) 里的解释。

## 3. spread 测试逐行解释

### `tests/spread/integration/arping/task.yaml`

```bash
rootfs="$(install-slices arping_bins base-passwd_data)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"
```
装 arping + `base-passwd_data`（提供 `nobody` 的 passwd 记录，缺了 arping
会报 `getpwnam(nobody): unknown user` 直接退出）。造假 `/dev/null`。

```bash
out="$(chroot "${rootfs}" /usr/sbin/arping -h 2>&1)"
echo "${out}" | grep -Fiq "arping 2."
echo "${out}" | grep -Fq "usage: arping"
```
冒烟。注意 arping 没有 `--version`，`-h` 就是打印版本行 +
用法（`ARPing 2.28, by Thomas Habets ...`）。用 `2>&1` 是因为它输出在 stderr，
而且不带 `-h` 也会顺带报 `invalid option -- '-'`。

```bash
gw="$(ip -4 route show default | awk '{print $3; exit}')"
iface="$(ip -4 route show default | awk '{print $5; exit}')"
test -n "${gw}"
test -n "${iface}"
```
从容器的路由表里取**默认网关 IP** 和**出口网卡名**。
`ip route show default` 输出形如
`default via 10.134.254.1 dev eth0 proto dhcp ...`，第 3 字段是网关，
第 5 字段是网卡。`awk ... exit` 只取第一条。

**为什么选默认网关做靶子**：mason 要求测试尽量自给自足，但 arping 的功能本身
*就是*发网络包，没有网络就什么都测不了 —— 这属于 CHISEL.md 里给 CA 证书/TLS
客户端开的那个例外（"当包的功能就是网络路径时"）。

默认网关是最好的选择：
- 它在**同一个二层广播域**里（ARP 不过路由器，只能打本地链路）；
- 它是容器网桥（LXD 的 `lxdbr0` / Docker 的 `docker0`），**一定会回应 ARP**
  —— 不回应容器就没法上网；
- **完全不出宿主机**，不碰外网，不依赖 DNS。

`test -n` 是防御：万一环境没有默认路由，测试要明确失败而不是拿空字符串去 ping。

```bash
arp() { chroot "${rootfs}" /usr/sbin/arping -i "${iface}" "$@"; }
```
helper。显式带 `-i` 指定网卡，不靠 arping 自己的自动探测（容器里可能有多张网卡，
探测结果不确定）。

```bash
out="$(arp -c 2 -w 5 "${gw}" 2>&1)"
echo "${out}" | grep -Fq "ARPING ${gw}"
echo "${out}" | grep -Eq "2 packets transmitted, [12] packets received"
```
**核心功能**：发 2 个 ARP 请求（`-c 2`），5 秒超时（`-w 5`）。

两条断言：
- `ARPING <ip>` —— 确认它在向正确的目标发送；
- `2 packets transmitted, [12] packets received` —— **收到了回应**。
  这一条走完了整条链路：libnet 构造帧 → 内核发出 → 对方回应 →
  libpcap 抓到 → arping 解析。

正则写 `[12]` 而不是 `2` 是留了容错：偶尔第一个包可能丢（网桥 MAC 表冷启动），
收到 1 个也算功能正常。但至少要收到 1 个，收 0 个就是失败。

`-w 5` 是**有界超时**，符合 mason "不许 sleep、不许无界重试"的要求。

```bash
mac="$(arp -r -c 1 -w 5 "${gw}")"
echo "${mac}" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
```
`-r`（raw output）只打印解析到的 MAC，不打印统计。正则严格要求
**整行**是标准 MAC 格式（6 组两位十六进制，冒号分隔）。这验证了 ARP 回应里的
硬件地址字段被正确提取出来了。

```bash
out="$(arp -q -c 1 -w 5 "${gw}")"
test -z "${out}"
```
`-q`（quiet）成功时**完全不输出**。

这里有个坑值得记：注意这行**没有 `2>&1`**，而上面几行都有。因为
**spread 用 `set -x` 跑 task**，xtrace 把 `+ chroot ... arping -q ...` 打到
stderr。如果写 `2>&1`，这行 trace 会被抓进 `${out}`，`test -z` 必然失败。
我第一版就是这么挂的，只抓 stdout 才对。

（前面几处用 `grep` 的断言不受影响，多几行 trace 无所谓。）

```bash
out="$(arp -0 -c 1 -w 5 "${gw}" 2>&1)"
echo "${out}" | grep -Eq "1 packets transmitted, 1 packets received"
```
`-0` 用 `0.0.0.0` 当发送方 IP。这是 DHCP 客户端探测 IP 冲突时的标准做法
（自己还没有 IP）。验证了一条不同的报文构造路径 —— libnet 要填一个全零的
sender IP，而对方仍然要回应。

```bash
out="$(arp -v -c 1 -w 5 "${gw}" 2>&1)"
echo "${out}" | grep -Fq "Interface: ${iface}"
```
`-v` 详细模式会先打印本机信息：
`This box: Interface: eth0  IP: 10.134.254.x  MAC address: ...`。
断言网卡名对得上，说明 arping 正确识别了本地接口配置
（这一步走的是 libpcap 的接口枚举 + ioctl 查地址）。

```bash
rc=0
arp -c 1 -w 2 169.254.111.222 >/dev/null 2>&1 || rc=$?
test "${rc}" -eq 1
```
**负向测试**。`169.254.0.0/16` 是 IPv4 链路本地地址段，
`169.254.111.222` 这个地址容器里没人用，不会有任何设备回应。

arping 在**没收到回应时退出码是 1**。精确断言 `-eq 1`（而不是笼统的"非 0"）
是为了区分"正确地报告了没人回应"和"程序崩了/参数错了"。

这条测试很重要 —— 没有它，一个"永远报成功"的假实现也能通过前面所有断言。

`-w 2` 只等 2 秒，不拖慢测试。

---

### `tests/spread/integration/libnet9/task.yaml`

`libnet9` 只在这个 PR 里出现（tcpdump 不需要它），所以**可以**用消费者验证，
写法和我最初给 libpcap 写的那版一致：

```bash
rootfs="$(install-slices libnet9_libs)"

for lib in "${rootfs}"/usr/lib/*-linux-*/libnet.so.9; do
  test -L "${lib}"
  target="$(readlink -f "${lib}")"
  test -f "${target}"
  head -c4 "${target}" | grep -Fq "ELF"
done
```
第一段：库文件本身的完整性。soname `libnet.so.9` 是符号链接，
指向 `libnet.so.9.0.0`，后者是 ELF。

```bash
rootfs="$(install-slices libnet9_libs arping_bins base-passwd_data)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"

gw="$(ip -4 route show default | awk '{print $3; exit}')"
iface="$(ip -4 route show default | awk '{print $5; exit}')"
test -n "${gw}"
test -n "${iface}"

out="$(chroot "${rootfs}" /usr/sbin/arping -i "${iface}" -c 1 -w 5 "${gw}" 2>&1)"
echo "${out}" | grep -Eq "1 packets transmitted, 1 packets received"
```
第二段：**换一个全新 rootfs**，把库和消费者装在一起。

这里的断言选得很有针对性：`arping` 发出去的每一个 ARP 帧都是 **libnet 拼装的**。
所以"收到 1 个回应"这件事本身就证明了：
- `libnet.so.9` 被动态链接器成功加载；
- 库里的报文构造函数正常工作，拼出来的是合法的 ARP 帧（否则对方不会回应）。

比单纯检查文件存在强得多 —— 这是 mason 对库切片的要求："pair with a consumer
where one exists"。
