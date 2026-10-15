# SONiC 是如何安装到物理交换机上的

本文介绍 SONiC（一个开源的网络操作系统 / NOS）是如何被安装到白盒交换机上的，以及整条引导链背后的底层知识

> 来源：仓库源码 `installer/default_platform.conf` 与文档
> `docs/superpowers/2026-09-09-onie-multiboot-and-ubuntu-sonic-install-sop-zh.md`。

---

## 一、先补必要背景知识

### 1. 白盒交换机（White Box Switch）

传统交换机（思科、华为）是「硬件 + 专用操作系统」绑定在一起出售。**白盒交换机**相反：硬件厂商（如 Dell、Edgecore）只做硬件，网络操作系统（NOS，Network Operating System）由用户自选——SONiC、Cumulus Linux 等都是可选 NOS。

所以装 SONiC 本质上就是「给一台裸 x86 服务器/交换机装一个操作系统」，和给服务器装 Ubuntu 没有本质区别。

### 2. 一台 x86 机器开机到进系统的完整链路

```
按下电源 → 固件(UEFI) → 引导加载器(GRUB) → 内核(kernel) → 根文件系统(用户空间)
```

### 3. 固件与引导

**固件（Firmware）** = 「硬件和操作系统之间的那层软件」的统称（路由器、显卡、硬盘里各有自己的固件）。就主板而言，它是一段**存在专用芯片里的程序，开机后 CPU 第一个执行**：先自检硬件（POST），再负责「找到能启动的操作系统并把它拉起来」。

固件存在主板一块 SPI Flash 芯片里（8~64 MB），CPU 上电即可无依赖读到，不依赖磁盘。

- **它能被覆写**——「刷 BIOS / 更新固件」就是擦掉重写这块 Flash。Flash 本身可擦可写
- 平时普通文件操作碰不到它，靠三点：① 它和磁盘数据**物理隔离**（不同芯片）；② 磁盘是「外设」，CPU 上电无法先依赖还没初始化的磁盘（鸡生蛋问题）；③ 往往带写保护锁
- **语言**：绝大多数用 **C**，只有上电最早、C 运行环境还没建立的那小段（初始化 CPU、设栈、切模式）必须用**汇编**，因为固件没有 OS 给的运行时（无堆/libc/进程）
- 基本不感知OS，固件只认「符不符合 UEFI 约定的 .efi 引导文件」，加载完就退居二线，不关心对方是 Windows 还是 Linux 还是 ONIE。安全启动也只校验数字签名，不认「你是什么 OS」
- **跟架构强相关，必须匹配**。固件是针对特定 CPU 架构编译的裸机程序（指令集/寄存器/启动流程完全不同，x86 固件跑不了 ARM）。`.efi` 文件也分架构：`grubx64.efi` 不能拿到 ARM 上跑。所以 SONiC 白盒交换机都是 x86_64 UEFI，用的是 `grubx64.efi` / `GRUBX64.EFI`。

一句话：固件「存在独立芯片上 + CPU 上电即可无依赖访问 + 常带写保护」。

BIOS 和 UEFI 是两代固件标准，固件是笼统概念，BIOS/UEFI 是新旧两代实现（类比「操作系统」之于 Windows XP 与 Windows 11）：

- **BIOS**：老标准，16 位、只认 MBR 分区表
- **UEFI**：新标准（SONiC 只用 UEFI），32/64 位，认 GPT 分区表，引导项是**文件路径**而非扇区地址，支持安全启动

「引导」= **把机器的控制权，从固件一步步交接到操作系统内核的过程**。内核是个复杂程序，而开机时什么环境都没有（内存未初始化、磁盘是外设、文件系统没人认识），所以不能「一开机直接跑内核」，必须分步接力：

1. 固件自检、初始化硬件（POST）
2. 固件加载**引导加载器**（bootloader，如 GRUB）
3. 引导加载器认识文件系统，加载**内核 + 初始内存盘**
4. 内核接管，完成初始化，进入用户空间

**固件由谁开发**

- **笔记本**：OEM（如联想）负责**定制、签名、发布**（按 F1 看到的界面是联想的），但底层核心大量来自 Intel 主导的开源 UEFI 实现（TianoCore/EDK2）；CPU 内部还有一层 Intel 签发的**微码（microcode）**。区分标准：**谁发布更新包、谁对它负责，谁就是「开发方」**——是联想
- **白盒交换机**：固件由**硬件制造商（或委托 ODM）负责**，SONiC 不写固件。白盒上「固件」要拆成几层，责任不同：

  | 层 | 内容 | 谁负责 |
  |------|------|------|
  | 主板 UEFI/BIOS | 引导硬件的固件 | 硬件制造商 / ODM |
  | ONIE | 装/卸/更新 NOS 的引导环境 | OCP 标准 + 硬件厂商落地适配 |
  | SONiC（NOS） | 真正跑转发的操作系统 | 你（或发行方） |
  | ASIC 固件 / SDK | 交换芯片（如 Broadcom）的程序 | ASIC 厂商 |

  关键区分：**「写固件程序本身」= 硬件厂商干；「改固件的引导配置」（NVRAM 变量、ESP 文件）= 操作系统干**（这正是后文「装完必查 efibootmgr」的原因）。SONiC 改的不是 Flash 里的固件代码，而是固件暴露出来的配置区和磁盘 ESP 里的文件。


### 4. UEFI NVRAM —— 重点

**NVRAM** = Non-Volatile RAM（非易失性内存）。可理解成：**固件自己的一块「配置存储」**，掉电不丢。其中关键是一张**引导项表**，每一项形如：

```
Boot0006* SONiC-OS  HD(1,GPT,b966357b-…,0x800,0x80000)/File(\EFI\SONIC-OS\GRUBX64.EFI)
```

翻译成人话：**「第 0006 号引导项，去 1 号硬盘第 1 个 GPT 分区（PARTUUID 是 b966357b…）里，找到 `/EFI/SONIC-OS/GRUBX64.EFI` 这个文件并执行它。」**

三个控制变量（类比「播放列表」）：

| 变量 | 含义 | 类比 |
|------|------|------|
| `BootOrder` | 引导项的**顺序**，依次尝试 | 播放列表顺序 |
| `BootNext` | **一次性**指定下次进哪项，用完作废 | 「下一首只放这首」 |
| `BootCurrent` | **当前**实际从哪项进来（只读，供排查） | 现在正在放哪首 |

这些变量可用 Linux 的 `efibootmgr` 命令查看/修改。

### 5. ESP 分区和 `.efi` 文件

**ESP** = EFI System Partition，一个 FAT 格式的小分区（通常 `/dev/sda1`，几百 MB）。UEFI 固件只认 FAT，从这里加载引导程序。

**`grubx64.efi`**：GRUB 引导器被编译打包成的**一个可执行文件**（UEFI 下程序都是 .efi 格式）。固件加载它，等于把「接力棒」交给 GRUB。

### 6. GRUB（引导加载器）

GRUB 是 Linux 世界最常用的引导器。它读自己的配置文件（`grub.cfg`，一个菜单），根据菜单加载 Linux 内核（`vmlinuz`）和初始内存盘（`initrd`），把控制权交给内核。

两个重要概念：

- **`prefix`**：每个 `grubx64.efi` 在**编译时**被写死一个路径，决定它去哪找 `grub.cfg`。这是后面「层 1 争抢」的祸根。
- **`configfile` / `chainloader`**：GRUB 菜单可**跳去加载另一个 GRUB 配置**，或**链式加载另一个 .efi 文件**（chainload）。这就是「一个引导器套另一个引导器」的机制。

### 7. PARTUUID 和 LABEL

- **PARTUUID**：GPT 分区表里每个分区的唯一 ID，存在分区表（磁盘头）。
- **LABEL**：文件系统的卷标（如 `SONiC-OS`），存在文件系统里。

引导链里到处用 `search --label SONiC-OS` 来「按名字找根分区」，而非写死 `/dev/sda4`。因为设备名可能变（插拔、枚举顺序），但 LABEL/UUID 稳定。

### 8. ONIE 是什么

ONIE（Open Network Install Environment）=「开放网络安装环境」，由 OCP（开放计算项目）主导。**它不是 U 盘，而是常驻磁盘的一层固件级引导环境**，专门负责给白盒交换机装/卸/更新 NOS。装完 NOS 它也不消失，一直待在独立分区，随时可重新进入。它有自己的 GRUB 和一套模式（Install / Rescue / Uninstall / Update / Embed ONIE）。

---

## 二、SONiC 的四层引导决策链

核心观点：**一台机器的引导决策分布在四层，每层都有自己的「默认项」和「一次性跳转」，互不知情。** 绝大多数引导事故都源于只改了某一层，却以为改的是全局。

```
┌─ 层 0  UEFI NVRAM ────────────────────────────┐
│  BootOrder/BootNext/BootCurrent               │
│  每项 = (分区 PARTUUID, EFI 可执行文件路径)      │
└──────────────┬─────────────────────────────────┘
               │ 固件加载某个 grubx64.efi
┌──────────────▼─ 层 1  入口 grub.cfg ───────────┐
│  ESP(sda1)/EFI/{onie,UBUNTU-NOS,SONIC-OS,debian}│
│  ⚠ /EFI/debian/grub.cfg 是多个 NOS 共享入口     │
└──────────────┬─────────────────────────────────┘
               │ configfile 跳去某分区完整 grub.cfg
┌──────────────▼─ 层 2  NOS 自己的 grub 菜单 ─────┐
│  saved_entry / next_entry / onie_entry         │
└──────────────┬─────────────────────────────────┘
               │ 若选中的是 SONiC
┌──────────────▼─ 层 3  SONiC 双镜像 ─────────────┐
│  /host/image-<ver>/ ；sonic-installer          │
└────────────────────────────────────────────────┘
```

### 层 0 · UEFI NVRAM（固件选哪把钥匙）

固件按 `BootOrder` 顺序去 ESP 找对应的 `grubx64.efi`。装两个 NOS 后实测：

```
BootOrder: 0006,0000,0004,0005,...
Boot0000* UBUNTU-NOS  .../EFI/UBUNTU-NOS/grubx64.efi
Boot0004* ONIE         .../EFI/ONIE/GRUBX64.EFI
Boot0006* SONiC-OS     .../EFI/SONIC-OS/GRUBX64.EFI
```

操作：`efibootmgr -o`（改持久顺序）、`-n`（一次性下次进某项）、`-c`（新建）、`-b X -B`（删除）。

⚠️ **坑**：ONIE 的 `onie-nos-install` 会动这一层——装完官方 SONiC 后，`Boot0000 UBUNTU-NOS` 这项会**整个消失**（分区和文件系统都还在，只是 NVRAM 里的引导项被清掉）。所以**装完必须查 `efibootmgr`，缺了就重建、重排**。

### 层 1 · 入口 grub.cfg 与 `/EFI/debian` 的争抢（最反直觉）

每个 `grubx64.efi` 编译时都嵌了 `prefix`，决定它去哪读配置。**Debian 系（含 Ubuntu、SONiC）的惯例 prefix 都是 `/EFI/debian`**。于是 ESP 里：

```
/EFI/onie/grubx64.efi
/EFI/UBUNTU-NOS/grubx64.efi
/EFI/SONiC-OS/grubx64.efi
/EFI/debian/grub.cfg   ← 只有一份，大家共用！
```

SONiC 安装脚本会**无条件覆盖**这个共享入口（源码 `installer/default_platform.conf:567-579`）：

```sh
search --no-floppy --label --set=root SONiC-OS   # 指向 SONiC-OS
set prefix=($root)'/grub'
configfile $prefix/grub.cfg
```

**后果**：装完 SONiC，即使固件按 `Boot0000 (UBUNTU-NOS)` 走，`UBUNTU-NOS/grubx64.efi` 也会去读 `/EFI/debian/grub.cfg`，而那份已写着「跳去 SONiC」——**层 0 选的项，未必决定你最终进哪个 OS**。这是双 NOS 共存里最反直觉的一点。

### 层 2 · NOS grub 的三个跳转变量

SONiC 生成的 `/host/grub/grub.cfg` 开头（`default_platform.conf:521-537`）：

| 变量 | 语义 | 谁写 |
|------|------|------|
| `saved_entry` | 持久默认项 | `grub-set-default` |
| `next_entry` | 一次性，消费后自动清 | `grub-reboot` / `grub-editenv` |
| `onie_entry` | 一次性进 ONIE，**并自动安排下次回到原处** | 由逻辑自动填 |

这些变量存在 `grubenv` 文件里（固定 1024 字节的小文件）。

两个真实咬过人的坑：

1. **`save_env` 写不回 ext4**：设了 `next_entry=ONIE` 进 ONIE 后变量没被消费，导致此后**每次**重启都进 ONIE 回不去。修法是挂载后整块重写一个干净的空 grubenv。
2. **残留 `onie_entry` 会让结果和 `BootNext` 完全对不上**：设了 `efibootmgr -n 0000`（Ubuntu），结果却落进 ONIE——因为链路末端 grubenv 里残留了个 `onie_entry`。**静态读配置解释不了，必须用 console 看真实引导过程。**

### 层 3 · SONiC 双镜像

SONiC 在 `sda4`（`/host`，标签 `SONiC-OS`）里以**目录**形式并存多个镜像：

```
/host/image-202605.1174613-ec1bb42e4/
/host/image-202605_resolute_sheldon.0-1d988dec/
```

`sonic-installer list` 显示 Current（正在跑）/ Next（下次启动）。**为什么只留两个镜像**：安装新镜像时，脚本只从旧 grub.cfg 里捞「当前正在运行」那一个 menuentry 和 ONIE 项（`default_platform.conf:552-555`），第三个镜像的菜单项不在捞取范围内就**静默消失**。这就是 A/B 双镜像 + 可回滚的机制。

### ONIE 自身的模式机（它内部也有一层）

ONIE 常驻在 `sda2`（标签 `ONIE-BOOT`，128MB），有自己的 grub 和五个菜单：Install / Rescue / Uninstall / Update / Embed。进哪个由两个 grubenv 变量决定：`onie_mode`（一次性，用完自动 reset）优先于 `onie_nos_mode`（持久标记）。**装过 NOS 的机器 `onie_nos_mode=yes`，进 ONIE 默认落在 Rescue，不会自动联网装机**——这是保护，但也意味着不能指望「重启进 ONIE 就开装」。

Rescue 模式很实用：起 dropbear + udhcpc，能拿到和正常系统**同一个**管理 IP，root 空密码 SSH——但 PATH 不完整、缺一堆工具，要用得先 `export PATH=/usr/sbin:/sbin:/usr/bin:/bin`。

---

## 三、一条完整的装机故事线

1. **勘察**：确认镜像与平台匹配（离线拆 `.bin` 验）、看 `efibootmgr -v` 摸清引导链、确认原系统开机不会自己改磁盘（cloud-init 的 `growpart` 会每次开机扩盘）。

2. **预置镜像**：把 `.bin` 放到与要动的盘无关的存储（如独立 eMMC），保证随时可回滚。

3. **缩容 + 双启动**：从原系统 `grub-editenv` 设 `next_entry=ONIE` 进 ONIE，在 ONIE 里缩容原分区、紧挨着建新分区（堵死 growpart），**同一次会话内**完成——中间不能重启回原系统，否则 growpart 会把分区扩回去。

4. **装机**：`onie-nos-install xxx.bin`。装完自动重启进新系统，立刻查 `sgdisk -p`（分区无空隙）、`dumpe2fs`（原系统 fs 干净）、`efibootmgr`（原系统引导项大概率没了，要重建重排）。

5. **传自建镜像**：高时延链路用并行多流 + 分片重传。

6. **装第二个镜像**：`sonic-installer install`，形成 A/B，`set-default` 回滚。

7. **验收**：`sonic-installer list`、`uname -r`、`show interfaces status`、判 ASIC 起没起。

---

## 四、一句话总结

**SONiC 装机不是「覆盖磁盘装系统」这么简单，而是往一条由「UEFI NVRAM 引导项 → ESP 里的 grubx64.efi 和共享 grub.cfg → NOS 自己的 grub 菜单 → SONiC 双镜像」组成的四层决策链里，塞进一个新的分支。** 每一层都能推翻上一层的意图，所以排查必须**从外往里**：`efibootmgr` 看 BootCurrent → 看 `/EFI/debian/grub.cfg` 指向谁 → 看目标分区 grubenv 有无残留变量 → 最后才看 NOS 内部。静态分析对不上时，用串口 console 看一次真实引导，别继续猜。

---

## 附：底层概念补充

### NVRAM 是硬件概念吗？运行后还有用吗？

- NVRAM 是**存储介质的统称**（非易失、可随机读写）。现代 UEFI 实际上把它存在 SPI Flash 里，不是字面意义的电池 RAM。
- **不只有固件读**：Linux 运行时也通过 `efivars`（`/sys/firmware/efi/efivars`）读写它，`efibootmgr` 就是干这个的。
- 所以运行期它依然有用：在系统里改的引导项会写进 NVRAM，下次开机固件按新配置走。

### NVRAM 和磁盘的区别

| 维度 | NVRAM（引导变量区） | 磁盘/SSD |
|------|------|------|
| 容量 | 极小（几十 KB~几 MB） | 巨大（GB/TB） |
| 内容 | 固件引导变量等少量配置 | OS、文件、用户数据 |
| 访问方式 | 固件接口（efivars），不是文件系统 | 文件系统按文件读写 |
| 谁管理 | 固件定义的数据结构（UEFI 规范） | 操作系统管理 |
| 位置 | 主板 SPI Flash / 电池 RAM | 独立存储设备 |

关键区别：**NVRAM 是「固件私有的、格式特殊的小配置区」，磁盘是「操作系统管理的、通用的大存储」。** 引导配置必须放在固件能直接、无依赖访问的地方（解决「鸡生蛋」），NVRAM 就是这个用途。