# PR #1171 — python3-smbus + libi2c0

<https://github.com/canonical/chisel-releases/pull/1171>

分支 `feat-26.04-python3-smbus`，目标分支 `ubuntu-26.04`。

## 1. 这几个包是干什么的

### 先讲 I2C 和 SMBus

**I2C**（Inter-Integrated Circuit，读作 "I-squared-C"）是一种**两根线**的
低速串行总线，1982 年飞利浦发明的，用来让主板上的芯片互相通信：

- **SCL**（时钟线）
- **SDA**（数据线）

所有设备挂在这两根线上，每个设备有一个 7 位地址（0x00–0x7F）。
主控（master，通常是 CPU 或南桥）发起读写，从设备（slave）响应。

**SMBus**（System Management Bus）是 Intel 在 I2C 之上定义的一个更严格的子集，
规定了超时、错误处理、以及一组标准的读写事务类型。PC 主板上的 I2C 基本都按
SMBus 规范来用。

**服务器/嵌入式设备上挂在 I2C/SMBus 上的典型器件：**

| 器件 | 干什么 |
|---|---|
| 温度传感器（LM75、TMP102） | 读主板/CPU 周边温度 |
| 电压电流监控（INA219、PMBus 电源） | 读功耗 |
| 风扇控制器 | 调转速 |
| **内存条上的 SPD EEPROM** | 读内存型号、容量、时序（`decode-dimms` 就是干这个） |
| 显示器的 **EDID** EEPROM | 读显示器支持的分辨率 |
| RTC 实时时钟芯片 | 读写时间 |
| 光模块（SFP/QSFP）的 EEPROM | 读光模块厂商、波长、收发光功率 |
| GPIO 扩展、LED 控制器 | 控制指示灯、复位信号 |

在**网络设备**上这特别重要 —— 交换机的风扇、电源、光模块状态全靠 I2C 读取。
SONiC 这类网络操作系统的平台驱动层大量使用 I2C。

Linux 内核把每条 I2C 总线暴露成字符设备 `/dev/i2c-0`、`/dev/i2c-1`……
（需要 `i2c-dev` 内核模块）。用户态程序 `open()` 它，然后用 `ioctl()` 发起事务。

### `libi2c0` —— I2C/SMBus 用户态库

`libi2c.so.0`，来自 `i2c-tools` 源码包。它把内核那套 `ioctl` 接口封装成
C 函数：`i2c_smbus_read_byte_data()`、`i2c_smbus_write_word_data()`、
`i2c_smbus_read_i2c_block_data()` 等等。

`i2c-tools` 里的命令行工具（`i2cdetect`、`i2cget`、`i2cset`、`i2cdump`、
`i2ctransfer`）都基于它。

### `python3-smbus` —— Python 绑定

同样来自 `i2c-tools` 源码包。提供一个 C 扩展模块 `smbus`，
把 `libi2c` 的函数暴露给 Python：

```python
import smbus

bus = smbus.SMBus(1)                       # 打开 /dev/i2c-1
temp = bus.read_word_data(0x48, 0x00)      # 从地址 0x48 的传感器读一个字
bus.write_byte_data(0x20, 0x01, 0xFF)      # 往 0x20 的 GPIO 扩展器写一字节
data = bus.read_i2c_block_data(0x50, 0, 32) # 从 EEPROM 读 32 字节
bus.close()
```

完整 API（16 个公开方法）：

| 方法 | SMBus 事务类型 |
|---|---|
| `write_quick` | Quick Command（只发地址位，用来探测设备存在） |
| `read_byte` / `write_byte` | Receive Byte / Send Byte（不带寄存器地址） |
| `read_byte_data` / `write_byte_data` | Read/Write Byte（带寄存器地址，最常用） |
| `read_word_data` / `write_word_data` | Read/Write Word（16 位） |
| `process_call` | Process Call（写一个字同时读回一个字） |
| `read_block_data` / `write_block_data` | Block Read/Write（SMBus 块传输，带长度字节） |
| `block_process_call` | Block Process Call |
| `read_i2c_block_data` / `write_i2c_block_data` | I2C 块传输（不带长度字节，读 EEPROM 常用） |
| `open` / `close` | 打开/关闭总线 |
| `pec` | 属性，开关 **PEC**（Packet Error Checking，SMBus 的 CRC-8 校验） |

用它的地方：Raspberry Pi 的各种传感器脚本、服务器/交换机的平台管理软件、
BMC 相关工具链。

## 2. 切片设计

### 依赖顺序

```
libi2c0 ──► python3-smbus
   │              │
 libc6        python3
（已切好）     （已切好）
```

两个包都来自 `i2c-tools` 源码包。注意**目标列表里的 `i2c-tools` 二进制包被跳过了**
（PR #1004 已经有人切过），但 `libi2c0` 是独立的二进制包，26.04 分支上还没有，
所以要在这个 PR 里补上。

### `libi2c0.yaml`

```yaml
package: libi2c0

essential:
  libi2c0_copyright:

slices:
  libs:
    hint: SMBus and I2C userspace library
    essential:
      libc6_libs:
    contents:
      /usr/lib/*-linux-*/libi2c.so.0*:

  copyright:
    contents:
      /usr/share/doc/libi2c0/copyright:
```

按 mason 的流程要先查其他分支有没有已有 SDF —— 所有分支都没有。
但我查了**已关闭的 PR #1004**（i2c-tools），里面有一个 `libi2c0.yaml`：

```yaml
package: libi2c0
essential:
  libi2c0_copyright:
slices:
  libs:
    essential:
      libc6_libs:
    contents:
      /usr/lib/*-linux-*/libi2c.so.0*:
  copyright:
    contents:
      /usr/share/doc/libi2c0/copyright:
```

和我独立写出来的结构**完全一致**，我只加了一个 `hint:`（v3 特性，那个 PR 没用）。
我在 PR 描述里注明了这一点 —— 如果将来 #1004 被重新提交，两边不会打架。

`libi2c.so.0*` 一条覆盖 soname 链接 `libi2c.so.0` 和真身 `libi2c.so.0.1.1`。

### `python3-smbus.yaml`

```yaml
package: python3-smbus

essential:
  python3-smbus_copyright:

slices:
  libs:
    hint: SMBus Python bindings
    essential:
      libc6_libs:
      libi2c0_libs:
      python3_core:
    contents:
      /usr/lib/python3/dist-packages/smbus-*.egg-info/**:
      /usr/lib/python3/dist-packages/smbus.cpython-314-*-linux-*.so:

  copyright:
    contents:
      /usr/share/doc/python3-smbus/copyright:
```

#### C 扩展模块的文件名怎么写

deb 里的文件是：

```
/usr/lib/python3/dist-packages/smbus.cpython-314-aarch64-linux-gnu.so
```

这个名字里有两个变量：**Python 版本**（`314` = 3.14）和**架构三元组**
（`aarch64-linux-gnu`）。不能写死。

我查了同仓库已有的写法，`libpython3.14-stdlib.yaml` 里有几十条这种路径：

```yaml
/usr/lib/python3.14/lib-dynload/_bz2.cpython-314-*-linux-*.so:
/usr/lib/python3.14/lib-dynload/_ssl.cpython-314-*-linux-*.so:
```

约定是 **`cpython-314-*-linux-*.so`** —— Python 版本写死（因为切片是绑定到
26.04 的 Python 3.14 的），架构三元组用 `*-linux-*` 通配。我完全照这个来。

（如果写成 `smbus.cpython-*.so` 会更宽松，但就丢掉了"这个切片对应 Python 3.14"
这个信息；Python 大版本变了的时候应该显式改 SDF 而不是悄悄匹配上。）

#### 为什么是 `python3_core` 而不是 `python3_standard`

这是我这次和 `python3-protobuf`（用了 `python3_standard`）做的一个区分。

`python3-smbus` 是**纯 C 扩展**，`smbus.so` 里没有任何 Python import ——
它只需要解释器本身能加载扩展模块。我实测用 `python3_core` 切出来的 rootfs
`import smbus` 完全正常。

而 `python3-protobuf` 是纯 Python 代码，要 import `json`、`datetime`、`re`、
`enum` 等一大堆标准库，必须 `python3_standard`。

按 mason 的"不要过度包含"准则，能用 `core` 就不用 `standard`。
（`standard` 会拉进整个 `libpython3-stdlib` 的二十多个切片。）

#### 排序细节

`contents` 两条的 ASCII 顺序：`smbus-*.egg-info/**` vs
`smbus.cpython-...`。`-` 是 0x2D，`.` 是 0x2E，所以 `smbus-` < `smbus.`，
egg-info 在前。CI 用 `LC_COLLATE=C sort -C` 检查，写反了会被卡。

essential 三条：`libc6_libs` < `libi2c0_libs`（`c` < `i`）< `python3_core`。

#### 丢弃的路径

```
/usr/share/doc/python3-smbus/changelog.Debian.gz -> ../libi2c0/changelog.Debian.gz
```

这是个指向 `libi2c0` 文档目录的符号链接（Debian 的共享 changelog 机制）。
属于 `/usr/share/doc/**` 里的非法律文件，按约定丢弃。

#### egg-info

`/usr/lib/python3/dist-packages/smbus-1.1.egg-info/` 里有 `PKG-INFO`
（`Name: smbus`、`Version: 1.1`）和 `top_level.txt`。带上它让
`importlib.metadata.version("smbus")` 能工作，理由同 python3-protobuf。

### maintainer script

`postinst` 只跑 `py3compile`。C 扩展不需要字节码编译，纯粹是 dh_python3 的
模板代码。不需要复现。

## 3. spread 测试逐行解释

两个 task.yaml。核心难点：**容器里没有 I2C 总线**。

要真的做一次 I2C 事务，需要：
1. 加载 `i2c-dev` 内核模块
2. 有一条真实的 I2C 总线，或者加载 `i2c-stub` 模块造一条假的
3. `/dev/i2c-N` 字符设备（主设备号 89）

已关闭的 PR #1004 里有一个 `setup-i2c-stub` 脚本就是走这条路。但在非特权
LXD 容器里 `modprobe` 被禁止，`mknod` 也不允许；CI 的 docker backend 更不可能。
6 个架构都要过，这条路走不通。

所以我的策略是：**用一个普通文件冒充 `/dev/i2c-N`**。

关键洞察：`smbus` 模块的工作流程是
1. `open("/dev/i2c-N", O_RDWR)` —— 普通文件**能打开成功**
2. 每次传输 `ioctl(fd, I2C_SMBUS, ...)` —— 普通文件会被内核拒绝，
   返回 **ENOTTY**（Errno 25，"Inappropriate ioctl for device"）

第 2 步的失败恰恰**证明了模块真的在发 ioctl 系统调用**，而不是在更早的地方
就出错了。配合精确的 errno 断言，这是一个相当强的验证。

---

### `tests/spread/integration/python3-smbus/task.yaml`

```bash
rootfs="$(install-slices python3-smbus_libs)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"

touch "${rootfs}/dev/i2c-9"
chmod 666 "${rootfs}/dev/i2c-9"
```
造假设备节点。选 `9` 是任意的，只要和真实总线号不冲突（容器里本来就没有）。
`chmod 666` 让它可读写。

```bash
chroot "${rootfs}" /usr/bin/python3 -c 'import smbus'
```
**最关键的一条冒烟**。`smbus.cpython-314-*.so` 的 `DT_NEEDED` 里有
`libi2c.so.0`（我用 `objdump -p` 确认过），所以 `import smbus` 能成功
**就证明 `libi2c0_libs` 这条 essential 生效了**，动态链接器把库找到并加载了。

如果我漏写 `libi2c0_libs`，这里会报
`ImportError: libi2c.so.0: cannot open shared object file`。

```bash
cp test_smbus.py "${rootfs}/test_smbus.py"
out="$(chroot "${rootfs}" /usr/bin/python3 /test_smbus.py)"
echo "${out}" | grep -Fq "ALL-SMBUS-CHECKS-PASSED"
echo "${out}" | grep -Fq "version 1.1"
echo "${out}" | grep -Fq "ioctl rejected as expected"
```
跑功能脚本。三条断言：脚本走到最后、egg-info 元数据能读到、ioctl 路径走到了。

### `test_smbus.py` 逐段解释

```python
assert smbus.__file__.startswith("/usr/lib/python3/dist-packages/smbus."), smbus.__file__
print("module", smbus.__file__)
```
确认加载的是**切片里那个扩展模块**，而不是别处的同名东西。
（`smbus.` 后面跟的是 `cpython-314-<arch>-linux-gnu.so`，架构相关所以只匹配前缀。）

```python
print("version", version("smbus"))
```
`importlib.metadata.version("smbus")` → `1.1`。验证 egg-info 切进来了 ——
没切的话抛 `PackageNotFoundError`。

```python
expected = {
    "block_process_call", "close", "open", "pec", "process_call",
    "read_block_data", "read_byte", "read_byte_data", "read_i2c_block_data",
    "read_word_data", "write_block_data", "write_byte", "write_byte_data",
    "write_i2c_block_data", "write_quick", "write_word_data",
}
present = {a for a in dir(smbus.SMBus) if not a.startswith("_")}
assert expected <= present, expected - present
```
**API 完整性检查**：16 个公开方法一个不少。

用 `<=`（子集）而不是 `==`，是为了向前兼容 —— 上游将来加新方法不会让测试失败。
断言失败时打印 `expected - present`（缺了哪些），方便定位。

这一条的价值：C 扩展如果编译时缺了某些 SMBus 功能（比如没启用 I2C block
transfer 支持），方法就不会注册进来。这条能发现那种情况。

```python
try:
    smbus.SMBus(999)
except FileNotFoundError as e:
    assert e.errno == errno.ENOENT, e
    print("missing bus ->", e.errno)
else:
    raise AssertionError("SMBus(999) unexpectedly succeeded")
```
**open(2) 错误传播测试**。`/dev/i2c-999` 不存在，`open()` 返回 ENOENT，
模块要把它翻译成 Python 的 `FileNotFoundError` 并保留 `errno`。

用 `try/except/else` 而不是 `pytest.raises` 风格：`else` 分支保证
"如果居然成功了"也会失败，不会静默通过。

```python
bus = smbus.SMBus()
try:
    bus.read_byte(0x50)
except OSError as e:
    assert e.errno == errno.EBADF, e
    print("unopened ->", e.errno)
else:
    raise AssertionError("read_byte on an unopened bus unexpectedly succeeded")
```
**文件描述符管理测试**。`smbus.SMBus()` 不带参数构造一个"未打开"的对象
（内部 fd = -1）。在它上面做传输应该得到 **EBADF**（Bad file descriptor）。

这验证模块正确初始化了内部状态，而不是拿一个未初始化的 fd 去 ioctl
（那可能误操作别的文件描述符）。

```python
bus = smbus.SMBus(9)
for call in (lambda: bus.read_byte(0x50),
             lambda: bus.write_quick(0x50),
             lambda: bus.read_byte_data(0x50, 0x00),
             lambda: bus.read_i2c_block_data(0x50, 0x00, 4)):
    try:
        call()
    except OSError as e:
        assert e.errno == errno.ENOTTY, e
    else:
        raise AssertionError("transfer on a non-i2c device unexpectedly succeeded")
print("ioctl rejected as expected")
```
**核心的 ioctl 路径测试。**

`smbus.SMBus(9)` 打开我造的 `/dev/i2c-9`（普通文件）—— **构造成功**，
说明 open 路径通了。

然后四种不同的传输各试一次：
- `read_byte` —— Receive Byte 事务
- `write_quick` —— Quick Command 事务
- `read_byte_data` —— Read Byte 事务（带寄存器地址）
- `read_i2c_block_data` —— I2C 块读事务

每一个都要求抛 `OSError` 且 **errno == ENOTTY**。

为什么是 ENOTTY 而不是别的：内核对普通文件不认识 `I2C_SMBUS` / `I2C_SLAVE`
这些 ioctl 命令码，返回 ENOTTY。**能拿到 ENOTTY 就说明 ioctl 系统调用真的
发出去了** —— 如果模块在更早的地方失败（参数校验、内存分配、地址设置），
errno 会是别的值。

选四种不同事务类型，是因为它们在 C 代码里走不同的分支（不同的 ioctl 命令码和
不同的参数结构体），一次覆盖多条路径。

用 `errno.ENOTTY` 常量而不是硬编码 `25` —— 虽然 ENOTTY 在所有目标架构上
都是 25，但用常量更清晰，也不怕将来加不常见的架构。

```python
bus.close()
try:
    bus.read_byte(0x50)
except OSError as e:
    assert e.errno == errno.EBADF, e
    print("after close ->", e.errno)
else:
    raise AssertionError("read_byte after close unexpectedly succeeded")
```
**close 语义测试**。`close()` 之后 fd 应该被置回无效状态，
再做传输得到 EBADF（而不是继续用一个已关闭的 fd —— 那是 use-after-close bug，
可能操作到别的文件）。

### 诚实说明

这个测试**没有做成一次真实的 I2C 数据交换**（读到真实的字节值）。
做不到的原因是需要内核模块（`i2c-dev` + `i2c-stub`），在 CI 的容器环境里
不可用。

我做到的是：模块加载、库链接、API 完整、四类事务的 ioctl 路径、
以及三种错误状态（ENOENT / EBADF / ENOTTY）的正确传播。
在无硬件条件下这是能达到的上限，而且比"import 一下就算过"强得多。

---

### `tests/spread/integration/libi2c0/task.yaml`

```bash
rootfs="$(install-slices libi2c0_libs)"

for lib in "${rootfs}"/usr/lib/*-linux-*/libi2c.so.0; do
  rel="${lib#"${rootfs}"}"
  test -L "${lib}"
  target="$(readlink -f "${lib}")"
  test -f "${target}"
  head -c4 "${target}" | grep -Fq "ELF"

  ld="$(find "${rootfs}/usr/lib" -maxdepth 2 -name 'ld*.so.*' -print -quit)"
  test -n "${ld}"
  out="$(chroot "${rootfs}" "${ld#"${rootfs}"}" --list "${rel}")"
  echo "${out}" | grep -Fq "libc.so.6 =>"
  ! echo "${out}" | grep -Fq "not found"
done
```
和 libpcap / libibverbs / libnet9 / libfreeipmi 用的是同一套
**动态链接器闭包验证**：`ld.so --list` 在 rootfs 内部递归解析依赖，
任何遗漏显示成 `not found`。详见 [1166-tcpdump.md](1166-tcpdump.md)。

`libi2c` 只依赖 libc，所以只断言一条正向 + 一条兜底。

```bash
rootfs="$(install-slices libi2c0_libs python3-smbus_libs)"
mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"

out="$(chroot "${rootfs}" /usr/bin/python3 -c \
  'import smbus; print(sorted(a for a in dir(smbus.SMBus) if a[0] != "_"))')"
echo "${out}" | grep -Fq "read_i2c_block_data"
echo "${out}" | grep -Fq "write_i2c_block_data"
```
**换新 rootfs**，和消费者配对。

断言选得有针对性：`read_i2c_block_data` / `write_i2c_block_data` 这两个方法
在 C 扩展里**直接调用 `libi2c` 的 `i2c_smbus_read_i2c_block_data()` /
`i2c_smbus_write_i2c_block_data()`**。这些符号能在方法表里出现，
说明扩展模块成功链接并加载了 `libi2c.so.0` —— 库真的可用，
不只是文件躺在那里。

（如果库没加载，`import smbus` 就会直接 ImportError，根本走不到打印方法列表。）
