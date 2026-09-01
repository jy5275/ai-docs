# PR #1164 — pciutils + libpci3 + pci.ids

<https://github.com/canonical/chisel-releases/pull/1164>

分支 `feat-26.04-pciutils`，目标分支 `ubuntu-26.04`。

## 1. 这几个包是干什么的

### `pciutils` —— PCI 总线检查工具

提供三个二进制：

| 程序 | 作用 |
|---|---|
| `lspci` | 列出系统所有 PCI/PCIe 设备。运维排查硬件的第一个命令 |
| `setpci` | 直接读写 PCI 设备的配置空间寄存器。调硬件、改 BAR、开关 bus master 用 |
| `pcilmr` | PCIe **L**ane **M**argining at the **R**eceiver。测 PCIe 链路的信号裕量，做信号完整性诊断 |

每个 PCI 设备都有一段 256 字节（PCIe 是 4096 字节）的**配置空间**，
里面固定位置放着厂商 ID、设备 ID、设备类别、BAR 地址等等。`lspci` 就是把这段
二进制解析成人能看懂的文字。

### `libpci3` —— 配置空间访问库

`libpci.so.3`，上面三个程序共用的库。它封装了访问配置空间的多种"后端"
（pcilib 里叫 access method）：

- `linux-sysfs` —— 读 `/sys/bus/pci/devices/*/config`（现在默认走这个）
- `linux-proc` —— 读 `/proc/bus/pci`（老接口）
- `dump` —— 从一个文本 dump 文件读（**这个对测试非常有用**，见下文）
- 还有 intel-conf1/conf2、ecam 等直接敲端口的方式

除了访问配置空间，它还负责把数字 ID 翻译成名字，这就要用到下一个包。

### `pci.ids` —— PCI ID 数据库

一个纯数据包，只有 `/usr/share/misc/pci.ids` 一个文件（约 1.3 MB 文本），
架构无关（`Architecture: all`）。内容是这样的层级文本：

```
8086  Intel Corporation
	100e  82540EM Gigabit Ethernet Controller
		8086 001e  PRO/1000 MT Desktop Adapter
```

有了它，`lspci` 才能把 `8086:100e` 显示成
`Intel Corporation 82540EM Gigabit Ethernet Controller`，否则只有一串十六进制。
它还包含设备类别名（`0200` → `Ethernet controller`）。

## 2. 切片设计

### 依赖顺序

必须**从叶子往根**切，因为 SDF 不能引用不存在的切片：

```
pci.ids  ──►  libpci3  ──►  pciutils
                 │
        libc6 / libudev1 / zlib1g（已切好）
                              │
                        libkmod2（已切好）
```

`libpci3` 的 `Depends` 里就有 `pci.ids`，所以 `libpci3_libs` 的 essential 要写
`pci.ids_data`。CI 的 `pkg-deps` 检查会把 deb 的 `Depends:` 和 SDF 里的
essential 做 diff 并贴到 PR 评论，写全了才不会被问。

### `pci.ids.yaml`

```yaml
package: pci.ids

essential:
  pci.ids_copyright:

slices:
  data:
    hint: PCI ID database
    contents:
      /usr/share/misc/pci.ids:

  copyright:
    contents:
      /usr/share/doc/pci.ids/copyright:
```

纯数据包 → `data` 切片，这是约定名。文件名 `pci.ids.yaml` 的 stem 正好是
`pci.ids`（Debian 包名允许点号），和 `package:` 一致。切片引用写
`pci.ids_data` —— chisel 按**最后一个下划线**拆包名和切片名，点号不影响。

### `libpci3.yaml`

```yaml
package: libpci3

essential:
  libpci3_copyright:

slices:
  libs:
    hint: PCI configuration space library
    essential:
      libc6_libs:
      libudev1_libs:
      pci.ids_data:
      zlib1g_libs:
    contents:
      /usr/lib/*-linux-*/libpci.so.3*:

  copyright:
    contents:
      /usr/share/doc/libpci3/copyright:
```

几个考虑：

- **`libpci.so.3*` 的星号**。deb 里有两个文件：`libpci.so.3`（符号链接）
  和 `libpci.so.3.14.0`（真身）。用 `libpci.so.3*` 一条搞定。mason 的规则说
  "单版本 soname 要去掉尾部 `*`"，但这里是"soname + 真名"两个文件，
  加 `*` 才对，而且和 `libkmod2`、`libudev1` 这些已有 SDF 的写法一致。
- **不用写 `symlink:`**。deb 里自带的符号链接 chisel 会原样保留，只有
  maintainer script 创建的链接才需要手动声明。
- **essential 排序**：`libc6_libs` < `libudev1_libs` < `pci.ids_data` <
  `zlib1g_libs`，按 ASCII（`c` < `u`，`l` < `p` < `z`）。
- **路径用 `*-linux-*`** 而不是 `aarch64-linux-gnu`，这样一个 SDF 覆盖所有架构。

### `pciutils.yaml`

```yaml
package: pciutils

essential:
  pciutils_copyright:

slices:
  # update-pciids is left out: ...
  bins:
    hint: PCI bus inspection utilities
    essential:
      libc6_libs:
      libkmod2_libs:
      libpci3_libs:
    contents:
      /usr/bin/lspci:
      /usr/bin/pcilmr:
      /usr/bin/setpci:

  copyright:
    contents:
      /usr/share/doc/pciutils/copyright:
```

**三个二进制放一个 `bins`**，没有拆成 `lspci-bin` / `setpci-bin`。理由：包里就
这么点东西，功能高度相关，而且已有的 `iproute2.yaml` 也是把一堆工具塞进一个
`bins`，注释里明确写了"当 iproute2 作为别人的依赖时，我们没法知道具体要哪个工具"。
同一个逻辑适用。

**`libkmod2_libs` 是必须的**：`objdump -p /usr/bin/lspci` 显示 `libkmod.so.2`
是 `DT_NEEDED`（`lspci -k` 要查设备对应的内核驱动模块）。哪怕它是硬依赖会被
传递带进来，也必须显式列出 —— reviewer 会跑 `lddtree` 逐个核对。

**扔掉 `/usr/sbin/update-pciids`**。这是个 shell 脚本，从
`https://pci-ids.ucw.cz/v2.2/pci.ids` 下载最新数据库覆盖 `/usr/share/misc/pci.ids`。
读了源码后确认它在 chisel rootfs 里必然失败：

```sh
if ! touch ${DEST} >/dev/null 2>&1 ; then
	${quiet} || echo "${DEST} is read-only, exiting." 1>&2
	exit 1
fi
```

镜像里 `/usr` 是只读的，第一步就退出。而且它还需要 `curl`/`wget`/`lynx`
三者之一，这三个都不在 `pciutils` 的 `Depends` 里。既不可用也不可测 → 不切。

### maintainer script

`preinst`/`postinst` 只是删旧版本残留的 `pci.ids.new` 之类临时文件，
对全新 rootfs 无影响，不需要复现。

## 3. spread 测试逐行解释

三个包各有一个 task.yaml。共同的设计思路：**全部自给自足**。
测试不依赖宿主机真的有 PCI 设备 —— CI 要在 amd64/arm64/armhf/ppc64el/s390x/riscv64
六个架构上跑，s390x 上根本没有 PCI 拓扑可言。

我用了两种造假手段：

**手段 A：配置空间 dump 文件**。pcilib 支持 `dump` 后端，`lspci -F <文件>` 可以
从 `lspci -x` 那种文本格式读设备。格式很简单：一行设备地址，然后每行
`偏移: 16 个十六进制字节`。

**手段 B：假的 sysfs 树**。pcilib 的 `linux-sysfs` 后端只需要
`/sys/bus/pci/devices/<地址>/{config,class,vendor,device,irq}` 这几个文件，
我在 rootfs 里手工造出来，`lspci`/`setpci`/`pcilmr` 就都能工作了。
（`setpci` 和 `pcilmr` 不支持 `-F`，只能用手段 B。）

两种手段描述的都是同一个设备：**8086:100e**（Intel 82540EM 千兆网卡），
子系统 `8086:001e`，类别 `0200`（以太网控制器），revision `03`。选它是因为
这型号在 `pci.ids` 里名字很有辨识度，适合做断言。

---

### `tests/spread/integration/pciutils/task.yaml`

```bash
rootfs="$(install-slices pciutils_bins)"

out="$(chroot "${rootfs}" /usr/bin/lspci --version)"
echo "${out}" | grep -Fq "lspci version"
out="$(chroot "${rootfs}" /usr/bin/setpci --version)"
echo "${out}" | grep -Fq "setpci version"
```
冒烟：两个程序能起来、动态库能解析。

```bash
printf '%s\n' \
  '00:03.0 Ethernet controller' \
  '00: 86 80 0e 10 07 00 10 00 03 00 00 02 00 00 00 00' \
  '10: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00' \
  '20: 00 00 00 00 00 00 00 00 00 00 00 00 86 80 1e 00' \
  '30: 00 00 00 00 00 00 00 00 00 00 00 00 0b 00 00 00' \
  > "${rootfs}/dump"
```
手写配置空间 dump。逐字节说明第一行：

| 偏移 | 字节 | 含义 |
|---|---|---|
| 0x00-01 | `86 80` | Vendor ID，小端 → `0x8086` = Intel |
| 0x02-03 | `0e 10` | Device ID → `0x100e` = 82540EM |
| 0x04-05 | `07 00` | Command 寄存器（I/O + Mem + Bus Master 使能） |
| 0x06-07 | `10 00` | Status 寄存器（有 capability 链表） |
| 0x08 | `03` | Revision ID |
| 0x09 | `00` | Prog IF |
| 0x0a | `00` | Subclass = 以太网 |
| 0x0b | `02` | Class = 网络控制器 |
| 0x0e | `00` | Header type = 普通设备 |

0x2c-0x2f 的 `86 80 1e 00` 是子系统 ID `8086:001e`；0x3c 的 `0b` 是 IRQ 11。

> 注：这里用 `printf` 而不是 heredoc 是被迫的。YAML 的 `execute: |` 块靠缩进
> 界定，heredoc 的内容和结束符必须顶格才不会被 shell 当成缩进内容，但顶格又会
> 提前结束 YAML 块，整个文件解析失败。踩过这个坑。

```bash
out="$(chroot "${rootfs}" /usr/bin/lspci -F /dump -nn -vv)"
echo "${out}" | grep -Fq "[8086:100e]"
echo "${out}" | grep -Fq "[0200]"
echo "${out}" | grep -Fq "Subsystem"
echo "${out}" | grep -Fiq "82540EM Gigabit Ethernet Controller"
```
`-F /dump` 用 dump 后端，`-nn` 同时显示数字 ID 和名字，`-vv` 详细模式。
四条断言分别验证：厂商/设备 ID 解析对、类别码解析对、子系统信息被解出来、
**名字查表成功**（最后一条其实同时验证了 `pci.ids` 被找到并解析了）。

```bash
printf '8086  ChiselVendor\n\t100e  ChiselDevice\n' > "${rootfs}/ids"
out="$(chroot "${rootfs}" /usr/bin/lspci -F /dump -i /ids)"
echo "${out}" | grep -Fq "ChiselVendor ChiselDevice"
```
`-i` 指定替代的 ID 数据库。我造了一个只有一条记录的假数据库，输出变成
`ChiselVendor ChiselDevice` —— 这**证明名字确实是从数据库文件查出来的**，
而不是编译进二进制的。

```bash
out="$(chroot "${rootfs}" /usr/bin/lspci -F /dump -mm -n)"
echo "${out}" | grep -Fq '"0200" "8086" "100e"'
```
`-mm` 是机器可读格式（脚本解析用），确认这条输出通路也正常。

```bash
out="$(chroot "${rootfs}" /usr/bin/setpci --dumpregs)"
echo "${out}" | grep -Fq "VENDOR_ID"
echo "${out}" | grep -Fq "DEVICE_ID"
out="$(chroot "${rootfs}" /usr/bin/setpci --help 2>&1)"
echo "${out}" | grep -Fq "Usage: setpci"
```
`--dumpregs` 打印 `setpci` 内置的寄存器符号名表（`VENDOR_ID`→偏移 0、
`DEVICE_ID`→偏移 2……），不碰硬件。

```bash
dev="${rootfs}/sys/bus/pci/devices/0000:00:03.0"
mkdir -p "${dev}"
printf '\x86\x80\x0e\x10\x07\x00\x10\x00\x03\x00\x00\x02\x00\x00\x00\x00' > "${dev}/config"
... (再追加三行，共 64 字节)
echo "0x020000" > "${dev}/class"
echo "0x8086"   > "${dev}/vendor"
echo "0x100e"   > "${dev}/device"
echo "11"       > "${dev}/irq"
```
**手段 B**：在 rootfs 里造假的 sysfs。注意 `class` 要写 `0x020000`
（24 位：class/subclass/progif），我一开始写成 `0x0200`，`lspci` 就把设备显示成
`Unclassified device [0002]` 了。

`config` 是二进制文件，和手段 A 的 dump 内容完全一致，只是从文本变成裸字节。

```bash
out="$(chroot "${rootfs}" /usr/bin/lspci -nn)"
echo "${out}" | grep -Fq "00:03.0"
echo "${out}" | grep -Fq "[8086:100e]"
```
**不带 `-F`** 运行 `lspci` —— 走默认的 sysfs 后端，证明生产环境里真正会用到的
那条代码路径也是通的。

```bash
out="$(chroot "${rootfs}" /usr/bin/setpci -s 00:03.0 VENDOR_ID DEVICE_ID CLASS_DEVICE)"
echo "${out}" | tr '\n' ' ' | grep -Fq "8086 100e 0200"
out="$(chroot "${rootfs}" /usr/bin/setpci -d 8086:100e SUBSYSTEM_VENDOR_ID)"
echo "${out}" | grep -Fq "8086"
```
`setpci` 真正读寄存器。两种设备选择方式都测了：`-s` 按总线地址，
`-d` 按 vendor:device。`setpci` 每个寄存器输出一行，所以用 `tr` 把换行换成空格
再一次性匹配。

```bash
chroot "${rootfs}" /usr/bin/setpci -s 00:03.0 LATENCY_TIMER=20
out="$(chroot "${rootfs}" /usr/bin/setpci -s 00:03.0 LATENCY_TIMER)"
echo "${out}" | grep -Fxq "20"
```
**写寄存器再读回来**。`setpci` 对 `config` 文件做 read-modify-write，
偏移 0x0d 被改成 `0x20`。这是 `setpci` 的核心功能（写），必须测到。
`grep -Fxq` 的 `-x` 要求整行完全匹配，避免 `20` 匹配到 `120` 之类。

```bash
out="$(chroot "${rootfs}" /usr/bin/pcilmr 2>&1)"
echo "${out}" | grep -Fq "pcilmr [--margin]"
out="$(chroot "${rootfs}" /usr/bin/pcilmr --scan 2>&1)"
echo "${out}" | grep -Fiq "lane margining"
```
`pcilmr` 需要真实 PCIe 链路才能做 margining，没法完整驱动。但它启动时会先
初始化 pcilib —— 没有可用后端时直接报
`pcilib: Cannot find any working access method.` 然后退出，连用法都不打印
（我最早的版本就是在这里失败的）。有了假 sysfs 树之后它能正常初始化，
打印用法，`--scan` 也能跑完并报告"没有支持 margining 的链路"。

这满足了 mason 的要求：**实在没法完整驱动的二进制，至少要跑起来并 grep 到它
自己的输出，证明动态链接能解析**。

---

### `tests/spread/integration/pci.ids/task.yaml`

`pci.ids` 是纯数据包，没有二进制。mason 的规则明确说这种包**不能只检查文件存在**，
必须和消费者一起装，证明消费者真的能用上这份数据。

```bash
rootfs="$(install-slices pci.ids_data pciutils_bins)"
test -s "${rootfs}/usr/share/misc/pci.ids"
```
装数据 + 装消费者。`test -s` 确认文件非空。

```bash
out="$(chroot "${rootfs}" /usr/bin/lspci -F /dump -vnn)"
echo "${out}" | grep -Fq "Intel Corporation"
echo "${out}" | grep -Fq "82540EM Gigabit Ethernet Controller"
echo "${out}" | grep -Fq "PRO/1000 MT Desktop Adapter"
```
三条断言分别对应 `pci.ids` 的三个层级：厂商名、设备名、**子系统名**。
子系统名要求同时匹配 `8086:100e` 设备下的 `8086 001e` 子项，是最深一层的查表，
证明数据库被完整解析而不是只读了个开头。

```bash
out="$(chroot "${rootfs}" /usr/bin/lspci -F /dump)"
echo "${out}" | grep -Fq "Ethernet controller"
```
类别名 `0200` → `Ethernet controller`，这是数据库里 `C` 段（class）的内容，
和上面的厂商段是不同的数据结构。

---

### `tests/spread/integration/libpci3/task.yaml`

```bash
rootfs="$(install-slices libpci3_libs)"

for lib in "${rootfs}"/usr/lib/*-linux-*/libpci.so.3; do
  test -L "${lib}"
  target="$(readlink -f "${lib}")"
  test -f "${target}"
  head -c4 "${target}" | grep -Fq "ELF"
done
```
库切片的基本检查：soname 是符号链接、指向的真身存在、真身是 ELF 文件
（前 4 字节是 `\x7fELF`）。

用 `for ... in` 遍历 glob 而不是 `find | head -1`，一是避免 SIGPIPE，
二是让多架构目录名自然展开。

```bash
rootfs="$(install-slices libpci3_libs pciutils_bins)"
out="$(chroot "${rootfs}" /usr/bin/lspci -F /dump -n)"
echo "${out}" | grep -Fq "8086:100e"
```
**换一个全新 rootfs**，把库和它的消费者装在一起，证明这个 `.so` 真的能被加载和
调用（不只是文件存在）。用 `-n` 纯数字输出，不涉及名字查表 —— 这里要验证的是
库本身能解析配置空间，而不是数据库。
