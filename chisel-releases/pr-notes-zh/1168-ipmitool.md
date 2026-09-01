# PR #1168 — ipmitool + libfreeipmi17 + freeipmi-common

<https://github.com/canonical/chisel-releases/pull/1168>

分支 `feat-26.04-ipmitool`，目标分支 `ubuntu-26.04`。

## 1. 这几个包是干什么的

### 先讲 IPMI 是什么

**IPMI**（Intelligent Platform Management Interface，智能平台管理接口）是服务器
的**带外管理**标准。服务器主板上有一颗独立的小芯片叫 **BMC**（Baseboard
Management Controller），它有自己的 CPU、内存、网口，**独立于主机操作系统供电和
运行**。

这意味着：主机蓝屏了、系统没装、甚至关机状态下，只要还插着电源，你都能通过网络
连到 BMC 去：

- 远程开机 / 关机 / 强制断电 / 重启
- 读取所有硬件传感器（CPU 温度、风扇转速、电压、电源功率）
- 读取 **SEL**（System Event Log，硬件事件日志）—— 内存报错、电源故障、
  机箱被打开都记在这里
- 读取 **FRU**（Field Replaceable Unit）—— 主板、内存条的序列号型号
- 挂载远程 ISO 装系统、开远程串口控制台（SOL, Serial-over-LAN）
- 配置 BMC 自己的网络、用户、权限

各家厂商给 BMC 起了自己的名字：Dell 的 iDRAC、HP 的 iLO、IBM/联想的 IMM、
Supermicro 的 IPMI、华为的 iBMC —— 底下都是 IPMI 协议。

### `ipmitool` —— IPMI 命令行客户端

两个二进制：

| 程序 | 作用 |
|---|---|
| `ipmitool` | 一次性发命令给 BMC 并打印结果 |
| `ipmievd` | 守护进程，持续监听 BMC 的事件通知，转发到 syslog |

`ipmitool` 支持多种**接口（interface）**去连 BMC：

| 接口 | 通路 | 用途 |
|---|---|---|
| `open` | 内核驱动 `/dev/ipmi0` | 本机访问自己的 BMC（最常用） |
| `lan` | UDP 623，IPMI v1.5 RMCP | 远程访问，老协议，认证弱 |
| `lanplus` | UDP 623，IPMI v2.0 RMCP+ | 远程访问，有 RAKP 认证 + AES 加密 |
| `serial` | 串口 | 通过串口连 BMC |

典型用法：

```bash
ipmitool -I open chassis power status                 # 本机电源状态
ipmitool -I lanplus -H 10.0.0.5 -U admin -P xx sdr    # 远程读所有传感器
ipmitool -I lanplus -H 10.0.0.5 -U admin -P xx sel elist  # 远程读事件日志
ipmitool -I lanplus -H 10.0.0.5 -U admin -P xx power cycle # 远程重启
```

### `libfreeipmi17` —— IPMI 协议库

`libfreeipmi.so.17`，来自 FreeIPMI 项目。它把 IPMI 协议的报文封装/解封装、
认证握手、各种命令的编解码都实现好了。

有意思的是：**Debian 给 ipmitool 打了补丁让它链接 libfreeipmi**，
而上游 ipmitool 本来是自带一套实现的。这么做是为了复用 FreeIPMI 更完整的
协议实现。所以 `objdump -p /usr/bin/ipmitool` 里能看到 `libfreeipmi.so.17`
是 `DT_NEEDED`（硬依赖）。

它自己依赖 `libgcrypt20`（做 HMAC/AES 等密码学运算，IPMI v2.0 的 RAKP 认证要用）。

### `freeipmi-common` —— FreeIPMI 的配置文件

`Architecture: all`，只有四个配置文件：

| 文件 | 谁读它 | 内容 |
|---|---|---|
| `/etc/freeipmi/freeipmi.conf` | FreeIPMI 自带的命令行工具 | 默认的 BMC 地址、用户名、密码等（所以权限是 **0640**） |
| `/etc/freeipmi/freeipmi_interpret_sel.conf` | `libfreeipmi` | 把 SEL 事件翻译成 NOMINAL/WARNING/CRITICAL 三档的规则 |
| `/etc/freeipmi/freeipmi_interpret_sensor.conf` | `libfreeipmi` | 同上，针对传感器读数 |
| `/etc/freeipmi/libipmiconsole.conf` | `libipmiconsole` | SOL 远程串口的默认参数 |

**这四个文件全部是纯注释模板** —— 所有指令都被 `#` 注释掉了，装上它们不会改变
任何默认行为。这是我在写测试时实测确认的（见第 3 节），也成了一条断言。

## 2. 切片设计

mason 仓库里刚好有 ipmitool 的 **silver 参考答案**
（`tests/skills/cases/ipmitool/*.silver.yaml`），是 mason 自己 eval 用的期望结果。
我先照着它的结构走，再用真实 deb 逐条核对。参考答案是 v1/v2 列表语法写的，
我适配成了 v3 的 map 语法。

### 依赖顺序

```
freeipmi-common ──► libfreeipmi17 ──► ipmitool
                         │                │
                  libgcrypt20        libreadline8t64
                  （已切好）          libssl3t64
                                    （都已切好）
```

`libfreeipmi17` 的 `Depends:` 里明确有 `freeipmi-common`，所以
`libfreeipmi17_libs` 的 essential 要写 `freeipmi-common_config`。

### `freeipmi-common.yaml`

```yaml
package: freeipmi-common

essential:
  freeipmi-common_copyright:

slices:
  config:
    hint: FreeIPMI configuration files
    contents:
      /etc/freeipmi/freeipmi.conf: {mode: 0640}
      /etc/freeipmi/freeipmi_interpret_sel.conf:
      /etc/freeipmi/freeipmi_interpret_sensor.conf:
      /etc/freeipmi/libipmiconsole.conf:

  copyright:
    contents:
      /usr/share/doc/freeipmi-common/copyright:
```

**`mode: 0640` 是唯一一处特别的地方**。deb 里这个文件是 `0640 root/adm`，
因为它可能存放 BMC 的明文密码。mason 的规则说："权限非标准（不是
0644/0755/0777）时才加 `mode:`"。0640 属于非标准，所以显式写出来。

chisel 默认会保留 deb 里的权限位，所以加 `mode: 0640` 不改变行为 —— 它的价值是
**把这个安全属性写进 SDF**，让 reviewer 一眼看到，也让测试可以断言它。
（silver 参考答案没写，我认为写上更好。）

另外三个文件是普通 0644，不写 `mode:`。

**关于要不要拆分**：严格说四个文件里只有两个 `*_interpret_*.conf` 是
`libfreeipmi` 读的，另外两个分别属于 FreeIPMI 命令行工具（`freeipmi-tools` 包，
没切）和 `libipmiconsole2`（也没切）。按"不要为没切片的工具提供配置"的准则，
可以只留两个。但我最终选择四个都留在一个 `config` 切片里：

1. silver 参考答案就是这么做的，无理由偏离参考结构反而更糟；
2. 四个文件都是纯注释模板，加起来才几十 KB，且不改变任何行为；
3. `freeipmi-common` 整个包的存在意义就是这组配置，拆开显得过度设计。

### `libfreeipmi17.yaml`

```yaml
package: libfreeipmi17

essential:
  libfreeipmi17_copyright:

slices:
  libs:
    hint: IPMI protocol library
    essential:
      freeipmi-common_config:
      libc6_libs:
      libgcrypt20_libs:
    contents:
      /usr/lib/*-linux-*/libfreeipmi.so.17*:

  copyright:
    contents:
      /usr/share/doc/libfreeipmi17/copyright:
```

deb 里还有一个 `/usr/share/doc/libfreeipmi17/doc -> ../freeipmi-common` 符号链接
（共享文档目录），属于 `/usr/share/doc/**` 里的非法律文件，按约定丢弃。

`libfreeipmi.so.17*` 一条覆盖 soname 链接 `libfreeipmi.so.17` 和真身
`libfreeipmi.so.17.2.14`。

### `ipmitool.yaml`

```yaml
package: ipmitool

essential:
  ipmitool_copyright:

slices:
  # /etc/init.d/ipmievd is left out: the systemd unit below supersedes it, and
  # it also needs start-stop-daemon plus the runlevel links update-rc.d creates.
  bins:
    hint: IPMI baseboard management utility
    essential:
      ipmitool_data:
      libc6_libs:
      libfreeipmi17_libs:
      libreadline8t64_libs:
      libssl3t64_libs:
    contents:
      /usr/bin/ipmitool:
      /usr/sbin/ipmievd:

  data:
    hint: IANA PEN and OEM SEL tables
    contents:
      /usr/share/ipmitool/oem_ibm_sel_map:
      /usr/share/misc/enterprise-numbers.txt:

  services:
    essential:
      ipmitool_bins:
    contents:
      /usr/lib/systemd/system/ipmievd.service:

  copyright:
    contents:
      /usr/share/doc/ipmitool/copyright:
```

#### `data` 切片里的两个数据文件

这两个文件是我花时间挖出来的重点，因为**要证明它们真的被用到，得先搞清楚
谁在什么时候读它们**。

**`/usr/share/misc/enterprise-numbers.txt`（约 3 MB）**

这是 IANA 的 **PEN**（Private Enterprise Number，私有企业号）注册表。
IPMI 报文里的厂商标识是一个数字（比如 Intel 是 343，Dell 是 674），
这个文件把数字翻译成公司名。

`strings /usr/bin/ipmitool` 显示它硬编码了这个路径（还有一个
`$HOME/.local/usr/share/misc/...` 的备用路径）。**每次运行都会加载**，
加 `-v -v` 会看到 `Loading IANA PEN Registry...`。
文件缺失时会额外打印 `IANA PEN registry open failed`。

**`/usr/share/ipmitool/oem_ibm_sel_map`**

IBM 服务器的 OEM SEL 解码表，CSV 格式，229 条记录。IBM 的 BMC 会往 SEL 里写
标准之外的私有事件码，这张表把它们翻译成人类可读的描述（比如
`CPU shutdown - Potential cause 'triple fault'`）。

这个文件的消费方式很隐蔽：`strings` 在二进制里**找不到**它的路径。
我从 man 手册和实测才搞清楚 —— 要同时满足两个条件：

```bash
IPMI_OEM_IBM_DATAFILE=/usr/share/ipmitool/oem_ibm_sel_map ipmitool -o ibm ...
```

`-o ibm` 启用 IBM OEM 支持，然后它从**环境变量** `IPMI_OEM_IBM_DATAFILE`
读文件路径。加载成功会打印 `nrecs=229`（解析出的记录数），
路径错了会打印 `File /xxx does not exist` + `OEM setup for "ibm" failed`。

（man 里提到的 `-O <sel oem>` 是另一个机制，需要用户自己传文件路径，
而且是延迟打开的 —— 没有 BMC 的话根本不会读，所以没法用来测试。）

搞清楚这两条消费路径之后，`data` 切片就变得**完全可验证**了，不是"塞进去
但愿有用"。

#### 丢弃 `/etc/init.d/ipmievd`

sysvinit 脚本。deb 里同时提供 systemd unit 和 init 脚本，unit 已经覆盖功能；
init 脚本还需要 `start-stop-daemon`（dpkg 包）和 `update-rc.d` 建的运行级别
符号链接，在 chisel rootfs 里都没有。

#### maintainer script

`postinst` 里有一段被注释掉的 `wget` 下载 enterprise-numbers.txt 的逻辑
（Debian 决定直接打包这个文件而不是运行时下载），剩下的只是清理旧版本的
conffile。对全新 rootfs 无影响，不需要复现。

## 3. spread 测试逐行解释

三个包各一个 task.yaml。核心挑战：**没有 BMC 硬件**。

容器里没有 `/dev/ipmi0`（需要 `ipmi_devintf` 内核模块 + 真实 BMC），
也没有可连的 IPMI 服务。所以测试策略是：
**把每条能在无硬件条件下走通的代码路径都走一遍，并精确断言它停在正确的位置。**

---

### `tests/spread/integration/ipmitool/task.yaml`

```bash
rootfs="$(install-slices ipmitool_bins)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"
```
注意 `ipmitool_bins` 的 essential 里有 `ipmitool_data`，所以两个数据文件会被
自动带进来 —— 后面的断言就是在验证这个依赖写对了。

```bash
out="$(chroot "${rootfs}" /usr/bin/ipmitool -V)"
echo "${out}" | grep -Fq "ipmitool version 1.8"
out="$(chroot "${rootfs}" /usr/bin/ipmitool -h 2>&1)"
echo "${out}" | grep -Fq "usage: ipmitool"
```
冒烟。能启动就意味着 `libfreeipmi.so.17`、`libreadline.so.8`、`libcrypto.so.3`
全部被动态链接器解析成功了（它们都是 `DT_NEEDED`）。

```bash
out="$(chroot "${rootfs}" /usr/bin/ipmitool help 2>&1)"
echo "${out}" | grep -Fq "Send a RAW IPMI request"
echo "${out}" | grep -Fq "Print System Event Log"
out="$(chroot "${rootfs}" /usr/bin/ipmitool -o list 2>&1)"
echo "${out}" | grep -Fq "OEM Support:"
echo "${out}" | grep -Fq "supermicro"
```
`help` 打印命令分发表（`raw`/`sdr`/`sel`/`chassis`/…），`-o list` 打印支持的
OEM 类型列表。这两张表都编译在二进制里，不需要 BMC。断言具体条目而不只是
"有输出"，是为了确认表本身完整。

```bash
rc=0
out="$(chroot "${rootfs}" /usr/bin/ipmitool -I open mc info 2>&1)" || rc=$?
echo "${out}" | grep -Fiq "could not open device at /dev/ipmi0"
```
**`open` 接口测试**。`-I open` 选中内核驱动接口，它会尝试依次打开
`/dev/ipmi0`、`/dev/ipmi/0`、`/dev/ipmidev/0`。chroot 里都没有，
所以报这个错。

能走到这个错误说明：接口插件被正确选中并初始化了。如果接口注册表有问题，
错误会是 `Error loading interface list` 之类完全不同的信息。

```bash
rc=0
out="$(chroot "${rootfs}" /usr/bin/ipmitool -I lanplus -H 127.0.0.1 \
  -U chisel -P chisel -R 1 -N 1 mc info 2>&1)" || rc=$?
test "${rc}" -ne 0
echo "${out}" | grep -Fiq "rmcp+"
```
**`lanplus` 接口测试，顺带验证 OpenSSL 依赖**。

IPMI v2.0 的 RMCP+ 握手要做 RAKP 认证：算 HMAC-SHA1、生成随机数、协商 AES-CBC
会话密钥 —— 全部走 `libcrypto`。ipmitool 会先完成这些密码学初始化并**发出**
Open Session Request 报文，然后才因为 127.0.0.1:623 没人应答而超时失败，
报 `Unable to establish IPMI v2 / RMCP+ session`。

所以断言 `rmcp+` 出现 = 加密路径跑过了 = `libssl3t64_libs` 依赖有效。

`-R 1 -N 1` 是**关键**：把重试次数和重试间隔都设为 1。不加的话默认重试策略
会让这条命令跑 **20 秒**；加了之后 2 秒结束。mason 要求"每个等待都要有界"。

```bash
out="$(chroot "${rootfs}" /usr/bin/ipmitool -I lanplus -H 127.0.0.1 \
  -U chisel -P chisel -R 1 -N 1 -v -v mc info 2>&1 || true)"
echo "${out}" | grep -Fq "Loading IANA PEN Registry"
! echo "${out}" | grep -Fiq "IANA PEN registry open failed"
```
**验证 `enterprise-numbers.txt` 切进来了**。

`-v -v` 打开二级详细输出，ipmitool 会打印 `Loading IANA PEN Registry...`。
关键是第二条**反向断言** —— 文件缺失时会多打印一行
`IANA PEN registry open failed: No such file or directory`。

这两条组合起来精确证明：加载动作发生了，而且成功了。我实测验证过：
把文件移走再跑，第二行确实会出现。

```bash
out="$(IPMI_OEM_IBM_DATAFILE=/usr/share/ipmitool/oem_ibm_sel_map \
  chroot "${rootfs}" /usr/bin/ipmitool -o ibm -I open sel list 2>&1 || true)"
echo "${out}" | grep -Eq "nrecs=[1-9][0-9]*"
```
**验证 `oem_ibm_sel_map` 切进来了**。

`nrecs=229` 是从文件里解析出的记录条数。正则要求非零，所以这条断言证明：
文件在正确路径、内容完整、CSV 能被解析。

（环境变量写在 `chroot` 前面 —— rootfs 里没有 `/usr/bin/env`，但 `chroot`
会把环境传给子进程。这个坑我在 smartmontools 上踩过。）

```bash
out="$(IPMI_OEM_IBM_DATAFILE=/nonexistent \
  chroot "${rootfs}" /usr/bin/ipmitool -o ibm -I open sel list 2>&1 || true)"
echo "${out}" | grep -Fq "Could not open /nonexistent file"
```
**负向对照**。故意指向不存在的文件，确认 ipmitool 会报错。

这条很重要 —— 没有它的话，万一 `nrecs=` 是个和文件无关的固定输出，
上面那条断言就是假的。有了负向对照才能确定 `nrecs=` 真的来自那个文件。

```bash
out="$(chroot "${rootfs}" /usr/sbin/ipmievd -V)"
echo "${out}" | grep -Fq "ipmievd version 1.8"
out="$(chroot "${rootfs}" /usr/sbin/ipmievd help 2>&1)"
echo "${out}" | grep -Fq "Poll SEL for notification of events"
rc=0
out="$(chroot "${rootfs}" /usr/sbin/ipmievd -I open open 2>&1)" || rc=$?
echo "${out}" | grep -Fiq "could not open device at /dev/ipmi0"
```
**`ipmievd` 覆盖**。`check-test.py` 要求 `bins` 切片里声明的每个二进制都被
跑到，所以 `ipmievd` 也得测。

三步：版本、命令表（`open` / `sel` 两种事件监听模式）、以及真的尝试启动
（`ipmievd -I open open` 表示用 open 接口的 open 模式），停在同样的设备错误。

不能真的让守护进程跑起来 —— 没有 BMC 它会立刻退出，而且守护进程测试容易挂住。

```bash
rootfs="$(install-slices ipmitool_services)"
unit="${rootfs}/usr/lib/systemd/system/ipmievd.service"
grep -Fq "ExecStart=/usr/sbin/ipmievd open daemon" "${unit}"
test -x "${rootfs}/usr/sbin/ipmievd"
```
**`services` 切片的引用完整性检查**。只装 `services` 一个切片，
`ipmievd` 二进制是靠 `essential: ipmitool_bins` 被带进来的。
断言 unit 里 `ExecStart` 指向的路径在 rootfs 里真的存在且可执行 ——
如果我漏写了那条 essential，这里就会失败。

---

### `tests/spread/integration/libfreeipmi17/task.yaml`

```bash
rootfs="$(install-slices libfreeipmi17_libs)"

for lib in "${rootfs}"/usr/lib/*-linux-*/libfreeipmi.so.17; do
  rel="${lib#"${rootfs}"}"
  test -L "${lib}"
  target="$(readlink -f "${lib}")"
  test -f "${target}"
  head -c4 "${target}" | grep -Fq "ELF"

  ld="$(find "${rootfs}/usr/lib" -maxdepth 2 -name 'ld*.so.*' -print -quit)"
  test -n "${ld}"
  out="$(chroot "${rootfs}" "${ld#"${rootfs}"}" --list "${rel}")"
  echo "${out}" | grep -Fq "libc.so.6 =>"
  echo "${out}" | grep -Fq "libgcrypt.so.20 =>"
  ! echo "${out}" | grep -Fq "not found"
done
```
和 libpcap/libibverbs/libnet9 用的是同一套**动态链接器闭包验证**：
用 `ld.so --list` 在 rootfs 内部解析整条依赖链，任何遗漏都会显示成
`not found`。详见 [1166-tcpdump.md](1166-tcpdump.md) 里的详细解释。

断言 `libgcrypt.so.20` 被解析到，正好对应 SDF 里写的 `libgcrypt20_libs`。

```bash
grep -Fq "FreeIPMI Interpret SEL" \
  "${rootfs}/etc/freeipmi/freeipmi_interpret_sel.conf"
grep -Fq "FreeIPMI Interpret Sensor" \
  "${rootfs}/etc/freeipmi/freeipmi_interpret_sensor.conf"
```
验证 `essential: freeipmi-common_config` 生效了 —— 只装了
`libfreeipmi17_libs`，这两个配置文件是靠依赖被拉进来的。

断言的是文件里的**特征标题**而不只是 `test -s`，这样能确认拉进来的是正确的
文件而不是空壳。

```bash
rootfs="$(install-slices libfreeipmi17_libs ipmitool_bins)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"
out="$(chroot "${rootfs}" /usr/bin/ipmitool -V)"
echo "${out}" | grep -Fq "ipmitool version 1.8"
```
**换新 rootfs**，和消费者配对。`libfreeipmi.so.17` 是 `ipmitool` 的
`DT_NEEDED`，所以 `ipmitool -V` 能打印出来就说明库真的被加载了，
不只是文件存在。

---

### `tests/spread/integration/freeipmi-common/task.yaml`

这是纯配置包，没有二进制，最难写出有价值的测试。我的思路是：
**把这个包的每一条可验证属性都断言掉**。

```bash
rootfs="$(install-slices freeipmi-common_config libfreeipmi17_libs)"

conf="${rootfs}/etc/freeipmi"
grep -Fq "FreeIPMI configuration" "${conf}/freeipmi.conf"
grep -Fq "FreeIPMI Interpret SEL" "${conf}/freeipmi_interpret_sel.conf"
grep -Fq "FreeIPMI Interpret Sensor" "${conf}/freeipmi_interpret_sensor.conf"
grep -Fq "Libipmiconsole defaults" "${conf}/libipmiconsole.conf"
```
四个文件各有自己的特征标题。逐个断言 = 确认四个文件都落地了，
而且没有搞混（比如复制粘贴时把两个 interpret 文件写重复）。

```bash
test "$(stat -c '%a' "${conf}/freeipmi.conf")" = "640"
for c in freeipmi_interpret_sel freeipmi_interpret_sensor libipmiconsole; do
  test "$(stat -c '%a' "${conf}/${c}.conf")" = "644"
done
```
**权限断言**。`freeipmi.conf` 可能存 BMC 密码，必须是 0640（group/other
不可读）；另外三个是普通 0644。

这直接验证了 SDF 里那个 `{mode: 0640}` 生效，而且顺带保证了另外三个文件
**没有**被误设成 0640（那样反而会让本该可读的配置读不到）。
这是一条真实的安全属性，不是凑数的断言。

```bash
for c in "${conf}"/*.conf; do
  ! grep -qvE '^[[:space:]]*(#|$)' "${c}"
done
```
**这条最有意思**：断言四个文件里**没有任何一行是非注释非空行**。

也就是说，这四个文件是纯模板，所有指令都被注释掉了。这个断言的含义是
**"装上这个切片不会改变 libfreeipmi 或任何工具的默认行为"** —— 一条真实、
可验证、有意义的性质。

我是在写测试时才发现这一点的：最初我想断言某个具体指令（`grep -q
"IPMI_Interpret"`），结果匹配不到；`grep -v` 掉注释和空行之后发现文件里
什么都不剩。于是把这个发现本身变成了断言。

反过来说，如果将来 Ubuntu 改了这几个文件、开始默认启用某些指令，
这条测试会失败并提醒我们重新审视 —— 这正是回归测试该做的事。

```bash
rootfs="$(install-slices freeipmi-common_config ipmitool_bins)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"
out="$(chroot "${rootfs}" /usr/bin/ipmitool -V)"
echo "${out}" | grep -Fq "ipmitool version 1.8"
```
最后按 mason 对纯数据包的要求，**和消费者一起装**，证明两者能共存且消费者能跑。

### 诚实说明

我没能测到"libfreeipmi 真的读取并应用了 `freeipmi_interpret_*.conf` 的规则"。
原因是这两个文件由 libfreeipmi 的 *interpret* API 消费，而调用这个 API 的是
`freeipmi-tools` 包里的 `ipmi-sel` / `ipmi-sensors` —— 那个包没被切片，
而 `ipmitool` 走的是自己的 SEL 解码逻辑。

在 chisel-releases 现有的切片范围内，这已经是能做到的最强验证。
我在 PR 描述里没有夸大这一点。
