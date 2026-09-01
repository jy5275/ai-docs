# PR #1166 — tcpdump + libpcap0.8t64 + libibverbs1

<https://github.com/canonical/chisel-releases/pull/1166>

分支 `feat-26.04-tcpdump`，目标分支 `ubuntu-26.04`。

## 1. 这几个包是干什么的

### `tcpdump` —— 抓包分析工具

网络排障的标准工具。它做两件事：

1. **抓包**：从网卡（或者读已有的 pcap 文件）取到原始以太网帧
2. **解码**：把二进制帧按协议层层解析成人类可读的文字

```bash
tcpdump -i eth0 'tcp port 80'        # 实时抓 eth0 上的 HTTP 流量
tcpdump -i eth0 -w cap.pcap          # 存成文件（之后可以用 Wireshark 打开）
tcpdump -r cap.pcap -nn -vv          # 从文件读并详细解码
tcpdump -d 'udp port 53'             # 只打印过滤器编译出的 BPF 字节码
```

关键选项：

| 选项 | 作用 |
|---|---|
| `-r <文件>` | 从 pcap 文件读，不抓网卡 |
| `-w <文件>` | 写 pcap 文件 |
| `-nn` | 不做 DNS 反查、不把端口号翻译成服务名 |
| `-e` | 显示链路层（MAC 地址、ethertype） |
| `-v` / `-vv` | 逐级详细（显示 TTL、IP ID、校验和等） |
| `-A` | 以 ASCII 打印载荷 |
| `-d` | 打印过滤器编译成的 BPF 汇编 |
| `-D` | 列出可抓包的接口 |
| `-Z <用户>` | 指定降权到哪个用户 |

**过滤器语法**（`tcp port 80`、`arp`、`host 10.0.0.1`）叫 BPF/pcap filter，
会被编译成内核 BPF 字节码，在内核里就把不要的包丢掉，避免全量拷到用户态。

### `libpcap0.8t64` —— 抓包库

`libpcap.so.0.8`。tcpdump、Wireshark、nmap、snort、suricata 全都基于它。
它抽象掉了各种抓包方式的差异（Linux 上是 `AF_PACKET` + `TPACKET_V3` 环形缓冲区，
BSD 上是 BPF 设备），并提供 pcap 文件的读写和过滤器编译器。

包名带 `t64` 后缀是因为 Ubuntu 24.04 起做了 **64-bit `time_t` 转换**
（32 位架构上 `time_t` 从 32 位变 64 位，ABI 不兼容，所以改了包名）。

有个容易踩的点：这个包里的 soname 和真实文件名的主版本号**不一致**：

```
/usr/lib/*/libpcap.so.0.8 -> libpcap.so.1.10.6
```

soname 停在 `0.8`（历史原因，为了 ABI 兼容不动它），实际文件走 `1.10.x`。
所以 SDF 里得写两条路径。

### `libibverbs1` —— InfiniBand / RDMA 用户态库

`libibverbs.so.1`。为什么抓包工具要依赖 RDMA 库？因为 libpcap 支持从 RDMA 网卡
（Mellanox/NVIDIA 那类）抓包，编译时链上了它。

`objdump -p libpcap.so.1.10.6 | grep NEEDED` 显示它是**硬依赖**（`DT_NEEDED`），
不是 `dlopen` 按需加载。也就是说没有它 libpcap 根本加载不了，
连 `tcpdump --version` 都跑不起来。所以必须切。

它自己依赖 `libnl-3-200` 和 `libnl-route-3-200`（netlink 库，这两个已经切好了）。

## 2. 切片设计

### 依赖顺序

```
libnl-3-200 / libnl-route-3-200（已切好）
        │
        ▼
   libibverbs1 ──┐
                 ├──► libpcap0.8t64 ──► tcpdump
   libdbus-1-3 ──┘                          │
   （已切好）                          libssl3t64（已切好）
```

### `libibverbs1.yaml`

```yaml
package: libibverbs1

essential:
  libibverbs1_copyright:

slices:
  # The adduser dependency is only used by the postinst, to create the "rdma"
  # group; maintainer scripts are handled differently in Chisel.
  libs:
    hint: InfiniBand and RDMA userspace library
    essential:
      libc6_libs:
      libnl-3-200_libs:
      libnl-route-3-200_libs:
    contents:
      /usr/lib/*-linux-*/libibverbs.so.1*:

  copyright:
    contents:
      /usr/share/doc/libibverbs1/copyright:
```

**`Depends: adduser` 没有对应的 essential**。它的 postinst 只做一件事：

```sh
getent group rdma > /dev/null 2>&1 || addgroup --system --quiet rdma
```

建一个 `rdma` 组，这是 maintainer script 的行为，运行时的库不需要 `adduser`。
CI 的 `pkg-deps` 检查会在评论里显示这个差异，所以我在 SDF 里写了注释解释。
（`iproute2.yaml` 对 `debconf` 依赖也是同样的处理方式，有先例。）

**hint 踩坑记录**：我最初写 `hint: InfiniBand verbs library`，CI 的
`validate-hints` 用 spaCy 做词性标注，把 "verbs" 判成了限定动词（finite verb），
报 `finite verbs are not allowed: verbs (verb)`。改成
`InfiniBand and RDMA userspace library` 就过了。我在虚拟机里装了同一套
spaCy 环境，提 PR 前本地跑一遍，避免这种来回。

### `libpcap0.8t64.yaml`

```yaml
package: libpcap0.8t64

essential:
  libpcap0.8t64_copyright:

slices:
  libs:
    hint: Packet capture library
    essential:
      libc6_libs:
      libdbus-1-3_libs:
      libibverbs1_libs:
    contents:
      /usr/lib/*-linux-*/libpcap.so.0.8:  # Symlink to libpcap.so.1.10.x
      /usr/lib/*-linux-*/libpcap.so.1.10*:

  copyright:
    contents:
      /usr/share/doc/libpcap0.8t64/copyright:
```

两条路径分开写（而不是一条 `libpcap.so.*`），是为了在 SDF 里把 soname 和真名
不一致这件事**记录下来**，注释直接说明 `0.8` 是指向 `1.10.x` 的符号链接。

`libpcap.so.1.10*` 只钉到 `major.minor`，不钉 patch —— mason 的规则：
钉死 patch 版本，包一升级 glob 就不匹配了。

`libdbus-1-3` 是因为 libpcap 支持从 D-Bus 抓消息（`dbus-system`/`dbus-session`
伪接口）。同样是 `DT_NEEDED`。

### `tcpdump.yaml`

```yaml
package: tcpdump

essential:
  tcpdump_copyright:

slices:
  # /etc/apparmor.d/usr.bin.tcpdump is left out: ...
  bins:
    hint: Network traffic capture and analysis
    essential:
      libc6_libs:
      libpcap0.8t64_libs:
      libssl3t64_libs:
    contents:
      # For live capture tcpdump drops privileges to the "tcpdump" user, ...
      /usr/bin/tcpdump:

  sysusers-config:
    contents:
      # The deb's postinst runs systemd-sysusers to create the "tcpdump" user;
      # maintainer scripts are handled differently in Chisel.
      /usr/lib/sysusers.d/tcpdump.conf:

  copyright:
    contents:
      /usr/share/doc/tcpdump/copyright:
```

#### `sysusers-config` 切片 —— 这个 PR 最有意思的地方

Debian/Ubuntu 的 tcpdump 打了补丁，**以 root 运行时会主动降权到 `tcpdump` 用户**。
deb 通过 `/usr/lib/sysusers.d/tcpdump.conf` 声明这个用户：

```
u! tcpdump - "tcpdump" /nonexistent
```

postinst 里跑 `systemd-sysusers tcpdump.conf` 把它写进 `/etc/passwd`。

Chisel 不跑 postinst，所以切出来的 rootfs 里没有这个用户。后果比我预想的严重
—— 我实测发现**连读 pcap 文件都会失败**：

```
$ chroot rootfs /usr/bin/tcpdump -nn -r /t.pcap
reading from file /t.pcap, link-type EN10MB (Ethernet), snapshot length 65535
tcpdump: Couldn't find user 'tcpdump'
```

也就是说降权是无条件的，不只发生在实时抓包时。

能不能在 SDF 里直接加一条 passwd 记录？不行：`/etc/passwd` 是 `base-passwd` 包
用 `text: FIXME` + `mutate:` 生成的，chisel 不允许两个包声明同一个非 `make`/`text`
路径，别的包碰不了它。而 `base-passwd` 的 `passwd.master` 里只有 Debian 基础用户
（root/daemon/bin/…/nobody），没有 `tcpdump`。

所以我的做法是：
1. 把 `/usr/lib/sysusers.d/tcpdump.conf` 单独切成 `sysusers-config`，
   镜像构建者可以在构建阶段跑 `systemd-sysusers` 把用户创建出来；
2. 在 `bins` 的注释里写清楚，不装这个切片就得用 `-Z <用户>`（`-Z root` 可行）。

切片名 `sysusers-config` 遵循"`<用途>-config`"的约定，而且有先例：
`systemd.yaml` 有 `sysusers-config` 切片，`dbus-system-bus-common.yaml` 把
`/usr/lib/sysusers.d/dbus.conf` 放在 `config` 里并配了同样意思的注释。

而且这个切片是**可测的**（见测试第二段），不是摆设。

#### 丢弃 apparmor profile

`/etc/apparmor.d/usr.bin.tcpdump`。理由：
1. 要生效必须有 `apparmor_parser` 加载它 + 内核开了 AppArmor；
2. 我 grep 过整个 `slices/`，**没有任何一个包**切自己的 apparmor profile，
   只有 `apparmor.yaml` 自己切 `/etc/apparmor.d/` 下的东西。跟随现有约定。

## 3. spread 测试逐行解释

三个 task.yaml。有个特殊约束：**`libpcap0.8t64` 和 `libibverbs1` 同时也是
`arping`（PR #1167）的依赖**。按要求两个 PR 各带一份，为了合并时不冲突，
这两个包的 SDF 和 task.yaml 在两个分支上必须**逐字节相同**。

这个约束直接影响了测试写法，下面会说。

---

### `tests/spread/integration/tcpdump/task.yaml`

#### 造 pcap 文件

```bash
hex() { printf '%b' "$(printf '%s' "$1" | tr -d ' ' | sed 's/../\\x&/g')"; }
make_pcap() {
  {
    hex 'd4c3b2a1 0200 0400 00000000 00000000 ffff0000 01000000'
    hex '01000000 00000000 2a000000 2a000000'
    hex 'ffffffffffff 020000000001 0806'
    hex '0001 0800 06 04 0001 020000000001 0a000001 000000000000 0a000002'
    hex '02000000 00000000 30000000 30000000'
    hex '020000000002 020000000001 0800'
    hex '4500 0022 0001 0000 40 11 66c8 0a000001 0a000002'
    hex '115c 115d 000e 0000'
    printf 'chisel'
  } > "$1"
}
```

`hex` 这个函数把 `'d4c3 b2a1'` 这样的十六进制字符串（可以带空格便于阅读）
转成裸字节：先 `tr -d ' '` 去空格，再 `sed` 每两个字符前面加 `\x`，
最后 `printf '%b'` 解释转义。

**手写 pcap 是为了完全脱离网络和硬件**。CI 要在 6 个架构上跑，容器里没有可靠的
流量可抓；而且抓包测试天生不确定（抓不到、抓到别的包）。手写文件字节固定，
每次结果一样。

逐段解释这些字节：

**pcap 全局文件头（24 字节）**

| 字段 | 字节 | 含义 |
|---|---|---|
| magic | `d4 c3 b2 a1` | 魔数，这个字节序表示文件是小端 |
| version | `0200 0400` | major 2, minor 4 |
| thiszone | `00000000` | 时区偏移，0 |
| sigfigs | `00000000` | 时间戳精度，0 |
| snaplen | `ffff0000` | 65535 |
| network | `01000000` | 链路类型 1 = `EN10MB`（以太网） |

**第 1 个包记录：ARP 请求**

记录头 `01000000 00000000 2a000000 2a000000` = 时间戳秒 1、微秒 0、
抓取长度 0x2a=42、原始长度 42。

以太网头 `ffffffffffff 020000000001 0806`：目的 MAC 全 F（广播）、
源 MAC `02:00:00:00:00:01`、ethertype `0x0806` = ARP。

ARP 报文 28 字节：`0001`（硬件类型=以太网）`0800`（协议类型=IPv4）
`06`（硬件地址长 6）`04`（协议地址长 4）`0001`（操作码=请求）
`020000000001`（发送方 MAC）`0a000001`（发送方 IP = 10.0.0.1）
`000000000000`（目标 MAC，请求时填 0）`0a000002`（目标 IP = 10.0.0.2）。

tcpdump 会解码成：`ARP, Request who-has 10.0.0.2 tell 10.0.0.1, length 28`

**第 2 个包记录：IPv4/UDP**

记录头：时间戳秒 2、长度 0x30=48。

以太网头：目的 `02:00:00:00:00:02`、源 `02:00:00:00:00:01`、
ethertype `0x0800` = IPv4。

IPv4 头 20 字节：`45`（版本4 + 头长5*4=20）`00`（TOS）`0022`（总长 34）
`0001`（ID）`0000`（标志/分片）`40`（TTL=64）`11`（协议 17 = UDP）
`66c8`（**头校验和**）`0a000001`（源 10.0.0.1）`0a000002`（目的 10.0.0.2）。

校验和 `0x66c8` 是我手算的：把头部按 16 位分组求和
（`4500+0022+0001+0000+4011+0000+0a00+0001+0a00+0002 = 0x9937`），取反
（`0xFFFF - 0x9937 = 0x66C8`）。算对很重要 —— `tcpdump -v` 会校验并打印
`bad cksum`，那样断言就不干净了。

UDP 头 8 字节：`115c`（源端口 4444）`115d`（目的端口 4445）`000e`（长度 8+6=14）
`0000`（校验和 0 = IPv4 下表示不校验）。载荷 6 字节 ASCII `chisel`。

tcpdump 解码成：`IP 10.0.0.1.4444 > 10.0.0.2.4445: UDP, length 6`

> 用 `printf` + `hex()` 而不是 heredoc：YAML 的 `execute: |` 块用缩进界定，
> heredoc 内容必须顶格才不会被当作缩进的一部分，但顶格会提前终止 YAML 块。
> 我第一版就是这么写的，`yaml.safe_load` 直接报错。

#### 测试主体

```bash
rootfs="$(install-slices tcpdump_bins)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"
make_pcap "${rootfs}/test.pcap"

out="$(chroot "${rootfs}" /usr/bin/tcpdump --version 2>&1)"
echo "${out}" | grep -Fq "tcpdump version 4.99"
echo "${out}" | grep -Fq "libpcap version"
out="$(chroot "${rootfs}" /usr/bin/tcpdump -h 2>&1)"
echo "${out}" | grep -Fq "Usage: tcpdump"
```
冒烟。`--version` 同时打印 tcpdump 和 libpcap 的版本，一条命令验证了两个包
都装对了。

```bash
td() { chroot "${rootfs}" /usr/bin/tcpdump -Z root -nn "$@"; }
```
包一个 helper。`-Z root` 是为了绕过降权（这个 rootfs 里没装
`sysusers-config`，也没建 `tcpdump` 用户）。`-nn` 关掉名字解析，
让输出稳定可断言（否则 `4445` 可能被翻译成服务名，`10.0.0.1` 可能被反查 DNS）。

```bash
out="$(td -r /test.pcap 2>&1)"
echo "${out}" | grep -Fq "ARP, Request who-has 10.0.0.2 tell 10.0.0.1"
echo "${out}" | grep -Fq "10.0.0.1.4444 > 10.0.0.2.4445: UDP, length 6"
```
**核心功能：协议解码**。两条断言分别验证 ARP 和 IPv4/UDP 解析器。
匹配的是完整的解码文本，说明字段全都解对了（IP、端口、载荷长度）。

```bash
out="$(td -e -r /test.pcap 2>&1)"
echo "${out}" | grep -Fq "02:00:00:00:00:01 > ff:ff:ff:ff:ff:ff"
echo "${out}" | grep -Fq "ethertype IPv4 (0x0800)"
```
`-e` 打开链路层解码。验证 MAC 地址和 ethertype 解析 —— 这是和上面不同的
代码路径（默认模式不解链路层）。

```bash
out="$(td -v -r /test.pcap 2>&1)"
echo "${out}" | grep -Fq "proto UDP (17)"
echo "${out}" | grep -Fq "ttl 64"
```
`-v` 详细模式，验证 IPv4 头里的协议号和 TTL 被解出来。
（顺带确认校验和算对了 —— 算错的话这里会多出 `bad cksum` 字样。）

```bash
out="$(td -A -r /test.pcap 2>&1)"
echo "${out}" | grep -Fq "chisel"
```
`-A` 以 ASCII 打印载荷，验证载荷提取正确（能看到我塞进去的 `chisel`）。

```bash
out="$(td -r /test.pcap 'udp port 4445' 2>&1)"
echo "${out}" | grep -Fq "10.0.0.2.4445"
! echo "${out}" | grep -Fq "ARP"
out="$(td -r /test.pcap 'arp' 2>&1)"
echo "${out}" | grep -Fq "ARP"
! echo "${out}" | grep -Fq "4445"
```
**BPF 过滤器**。两个方向都测，而且**都带反向断言**：
过滤 UDP 时 ARP 包必须被滤掉，过滤 ARP 时 UDP 包必须被滤掉。
只断言"匹配的包出现了"是不够的 —— 过滤器完全失效（全放过）也能通过。

```bash
out="$(td -d -r /test.pcap 'udp port 4445' 2>&1)"
echo "${out}" | grep -Fq "ldh"
echo "${out}" | grep -Fq "jeq"
```
`-d` 打印过滤器编译出的 BPF 汇编（`ldh [12]` 加载 ethertype、
`jeq #0x86dd` 比较……）。这验证的是 libpcap 的**过滤器编译器**，
和上面的运行时过滤是不同的组件。

```bash
td -w /out.pcap -r /test.pcap 'arp'
out="$(td -r /out.pcap 2>&1)"
echo "${out}" | grep -Fq "ARP, Request who-has 10.0.0.2 tell 10.0.0.1"
! echo "${out}" | grep -Fq "4445"
```
**pcap 写入路径**。边读边写，只写 ARP 包，然后把新文件读回来核对：
ARP 包在、UDP 包不在。这证明 `-w` 生成的文件格式合法（能被自己读回来）
且过滤在写入时也生效。

```bash
chroot "${rootfs}" /usr/bin/tcpdump -Z root -D >/dev/null
```
`-D` 列接口，走的是 libpcap 的 `pcap_findalldevs()`，
不需要抓包权限。这是唯一一个真的碰真实网络栈的调用。

#### 第二段：`sysusers-config`

```bash
rootfs="$(install-slices tcpdump_bins tcpdump_sysusers-config \
  base-passwd_data systemd_standard)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"
make_pcap "${rootfs}/test.pcap"

! grep -q "^tcpdump:" "${rootfs}/etc/passwd"
chroot "${rootfs}" /usr/bin/systemd-sysusers tcpdump.conf
grep -q "^tcpdump:" "${rootfs}/etc/passwd"

out="$(chroot "${rootfs}" /usr/bin/tcpdump -nn -r /test.pcap 2>&1)"
echo "${out}" | grep -Fq "ARP, Request who-has 10.0.0.2 tell 10.0.0.1"
```
这段证明 `sysusers-config` 切片是**真的有用**，不是为了好看：

1. `base-passwd_data` 提供 `/etc/passwd`，`systemd_standard` 提供
   `/usr/bin/systemd-sysusers`（我查了 `systemd.yaml`，这个二进制在
   `standard` 切片里）；
2. 先断言 `/etc/passwd` 里**没有** `tcpdump` 用户（初始状态）；
3. 在 chroot 里跑 `systemd-sysusers tcpdump.conf` —— 它读我切进来的那个
   drop-in 文件；
4. 断言用户被建出来了；
5. **不带 `-Z`** 跑 tcpdump，成功解码 —— 证明降权找到了用户。

这是完整的端到端验证：切片 → 工具消费切片 → 目标程序因此可用。

---

### `tests/spread/integration/libpcap0.8t64/task.yaml`

这个测试**必须在 tcpdump 和 arping 两个分支上完全一致**，所以不能用
`tcpdump_bins` 当消费者（arping 分支上没有那个切片）。

我第一版就是用 tcpdump 当消费者的，在 arping 分支上跑直接失败
（`chisel cut` 找不到 `tcpdump_bins`）。改成下面这种不依赖任何消费者的写法：

```bash
rootfs="$(install-slices libpcap0.8t64_libs)"

for lib in "${rootfs}"/usr/lib/*-linux-*/libpcap.so.0.8; do
  rel="${lib#"${rootfs}"}"
```
遍历 glob（多架构目录名不写死），`rel` 是去掉 rootfs 前缀后的绝对路径，
后面在 chroot 里要用。

```bash
  test -L "${lib}"
  target="$(readlink -f "${lib}")"
  test -f "${target}"
  head -c4 "${target}" | grep -Fq "ELF"
```
soname 是符号链接、指向的真身存在、真身是 ELF。

```bash
  ld="$(find "${rootfs}/usr/lib" -maxdepth 2 -name 'ld*.so.*' -print -quit)"
  test -n "${ld}"
  out="$(chroot "${rootfs}" "${ld#"${rootfs}"}" --list "${rel}")"
  echo "${out}" | grep -Fq "libc.so.6 =>"
  echo "${out}" | grep -Fq "libibverbs.so.1 =>"
  echo "${out}" | grep -Fq "libdbus-1.so.3 =>"
  ! echo "${out}" | grep -Fq "not found"
done
```
**用动态链接器本身来验证依赖闭包**。这是这个测试的核心思路。

`ld.so --list <文件>` 就是 `ldd` 内部干的事：解析 ELF 的 `DT_NEEDED`，
递归查找每个依赖，打印映射结果。找不到的会显示 `xxx.so => not found`。

在 chroot 里跑它，等于问："这个切片声明的依赖，是否足够让这个库被加载？"
输出长这样：

```
	libc.so.6 => /lib/aarch64-linux-gnu/libc.so.6 (0x...)
	libibverbs.so.1 => /lib/aarch64-linux-gnu/libibverbs.so.1 (0x...)
	libdbus-1.so.3 => /lib/aarch64-linux-gnu/libdbus-1.so.3 (0x...)
	libnl-route-3.so.200 => ...
	libnl-3.so.200 => ...
	libsystemd.so.0 => ...
```

三条正向断言挑了三个不同来源的依赖（libc6、libibverbs1、libdbus-1-3），
最后一条 `! grep "not found"` 是**兜底**：任何一个我漏写的依赖都会在这里暴露，
包括传递依赖（libnl、libsystemd 那几个）。

用 `find -print -quit` 找链接器而不是写死名字，因为各架构名字不同：
`ld-linux-aarch64.so.1`、`ld-linux-x86-64.so.2`、`ld64.so.1`（s390x）、
`ld64.so.2`（ppc64el）、`ld-linux-riscv64-lp64d.so.1`（riscv64，而且在
triplet 子目录里，所以 `-maxdepth 2`）。`-print -quit` 找到一个就停，
同时避免 `| head -1` 的 SIGPIPE 问题。

这个写法的好处不只是解决了跨分支一致性 —— 它比"跑一下消费者"更**直接**地检验了
库切片该负责的事（依赖完整性），而且完全不依赖同分支有什么别的包。

---

### `tests/spread/integration/libibverbs1/task.yaml`

和上面完全同构，只是换了库名和断言的依赖：

```bash
rootfs="$(install-slices libibverbs1_libs)"
for lib in "${rootfs}"/usr/lib/*-linux-*/libibverbs.so.1; do
  ...
  out="$(chroot "${rootfs}" "${ld#"${rootfs}"}" --list "${rel}")"
  echo "${out}" | grep -Fq "libc.so.6 =>"
  echo "${out}" | grep -Fq "libnl-3.so.200 =>"
  echo "${out}" | grep -Fq "libnl-route-3.so.200 =>"
  ! echo "${out}" | grep -Fq "not found"
done
```
断言两个 netlink 库都被解析到 —— 正好对应 SDF 里写的
`libnl-3-200_libs` 和 `libnl-route-3-200_libs`。
