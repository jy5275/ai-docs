# chisel-releases 26.04 切片工作说明（中文）

这个目录放的是我为 `canonical/chisel-releases` 的 `ubuntu-26.04` 分支提交的每个 PR
的通俗解释文档。**这些文档只在本地，不会提交进 git**（已加入
`.git/info/exclude`）。

## 目录

| 文档 | PR | 包 |
|---|---|---|
| [1163-bridge-utils.md](1163-bridge-utils.md) | [#1163](https://github.com/canonical/chisel-releases/pull/1163) | `bridge-utils` |
| [1164-pciutils.md](1164-pciutils.md) | [#1164](https://github.com/canonical/chisel-releases/pull/1164) | `pciutils` `libpci3` `pci.ids` |
| [1165-smartmontools.md](1165-smartmontools.md) | [#1165](https://github.com/canonical/chisel-releases/pull/1165) | `smartmontools` |
| [1166-tcpdump.md](1166-tcpdump.md) | [#1166](https://github.com/canonical/chisel-releases/pull/1166) | `tcpdump` `libpcap0.8t64` `libibverbs1` |
| [1167-arping.md](1167-arping.md) | [#1167](https://github.com/canonical/chisel-releases/pull/1167) | `arping` `libnet9` `libpcap0.8t64` `libibverbs1` |
| [1168-ipmitool.md](1168-ipmitool.md) | [#1168](https://github.com/canonical/chisel-releases/pull/1168) | `ipmitool` `libfreeipmi17` `freeipmi-common` |
| [1169-radvd.md](1169-radvd.md) | [#1169](https://github.com/canonical/chisel-releases/pull/1169) | `radvd` |
| [1170-python3-protobuf.md](1170-python3-protobuf.md) | [#1170](https://github.com/canonical/chisel-releases/pull/1170) | `python3-protobuf` |
| [1171-python3-smbus.md](1171-python3-smbus.md) | [#1171](https://github.com/canonical/chisel-releases/pull/1171) | `python3-smbus` `libi2c0` |

### 跳过的包

| 包 | 依据 |
|---|---|
| `ethtool` | PR [#881](https://github.com/canonical/chisel-releases/pull/881) OPEN → `ubuntu-26.04`（[#813](https://github.com/canonical/chisel-releases/pull/813) 也含） |
| `i2c-tools` | PR [#1004](https://github.com/canonical/chisel-releases/pull/1004) CLOSED 未合并 → `ubuntu-26.04` |
| `python3-netifaces` | PR [#276](https://github.com/canonical/chisel-releases/pull/276) OPEN / [#303](https://github.com/canonical/chisel-releases/pull/303) CLOSED → `ubuntu-24.04` |

判定方法：拉取上游全部 1022 个 PR 的文件清单（`gh api .../pulls/N/files`），
逐个匹配 `slices/<包名>.yaml` 和 `tests/spread/integration/<包名>/`，
再对照 `upstream/ubuntu-26.04` 分支上已有的 689 个 SDF。

---

## 先搞懂几个概念

### Chisel 是干什么的

传统容器镜像装一个 `.deb` 会把整包内容全部塞进去：可执行文件、man 手册、
changelog、示例脚本、shell 补全……但运行时其实只需要其中几个文件。

Chisel 把一个 deb 切成若干个命名的**切片（slice）**，构建镜像时只挑需要的切片。
它不是"装包再删文件"，而是直接从 deb 里按路径清单提取，所以镜像里根本不存在
多余文件，攻击面和体积都小很多。

命令长这样：

```bash
chisel cut --release ubuntu-26.04 --root ./rootfs tcpdump_bins
```

`tcpdump_bins` 就是"tcpdump 这个包的 bins 切片"。下划线前面是 deb 包名，
后面是切片名。

### SDF（Slice Definition File）

每个包对应一个 `slices/<包名>.yaml`，描述它有哪些切片、每个切片包含哪些路径、
依赖哪些别的切片。例如：

```yaml
package: bridge-utils          # 必须和文件名一致

essential:                     # 文件级依赖：本文件里每个切片都自动带上
  bridge-utils_copyright:

slices:
  bins:
    hint: Ethernet bridge administration   # v3 才有，40 字符以内的名词短语
    essential:                             # 这个切片额外需要的依赖
      libc6_libs:
    contents:                              # 从 deb 里提取哪些路径
      /usr/sbin/brctl:

  copyright:                               # 约定：copyright 切片放最后
    contents:
      /usr/share/doc/bridge-utils/copyright:
```

几个必须遵守的点（CI 会卡）：

- `26.04` 分支的 `chisel.yaml` 是 `format: v3`，`essential:` **必须写成 map**
  （`libc6_libs:`），写成列表（`- libc6_libs`）会解析失败。老分支（22.04/24.04）
  反过来必须用列表。
- `contents:` 里的路径、`essential:` 里的条目都必须按 **ASCII 字节序**排好，
  CI 用 `LC_COLLATE=C sort -C` 检查。
- 多架构库路径用 `*-linux-*` 通配，不要写死 `aarch64-linux-gnu`。
- man 手册、shell 补全、`/usr/share/doc/**`（除了 `copyright` 和上游 LICENSE 之类）、
  `lintian/overrides`、示例文件，一律不切。
- `hint:` 要是名词短语，不能有限定动词，不能以冠词开头。CI 用 spaCy 做词性分析。
  （我踩过坑：`InfiniBand verbs library` 里的 "verbs" 被判成动词，只好改成
  `InfiniBand and RDMA userspace library`。）

### 切片命名约定

| 名字 | 放什么 |
|---|---|
| `bins` | 可执行文件（复数，不是 `bin`） |
| `libs` | 共享库（复数，不是 `lib`） |
| `config` / `<用途>-config` | 配置文件 |
| `scripts` | shell 脚本之类的非二进制可执行文件 |
| `data` | 静态数据（数据库、模板、字体） |
| `services` | systemd unit 文件 |
| `var` | `/var/` 下的东西 |
| `copyright` | deb 的 copyright 文件（必备） |

### 最关键的一条：Chisel 不跑 maintainer script

装 deb 时 `postinst` 会做很多事：建符号链接、建用户、把文件从 A 拷到 B、
`ldconfig`、注册 alternatives……**Chisel 完全不执行这些**。

所以看到 postinst 里有动作，必须自己在 SDF 里复现：

- 简单的符号链接、目录 → 直接在 `contents:` 里声明
- 从别处拷文件 → 用 `copy:`（smartmontools 的 drivedb 就是这么做的）
- 需要逻辑 → 写 `mutate:`（Starlark 脚本，不是 Python）
- 建系统用户 → chisel 做不到，只能靠 `base-passwd` 里已有的，或者让使用者自己
  跑 `systemd-sysusers`（tcpdump 就是这个情况）

### spread 测试

`tests/spread/integration/<包名>/task.yaml` 是集成测试，在临时 LXD 容器里跑。
两层验证：

1. **可安装性** —— `chisel cut` 能成功，SDF 语法对、依赖能解析、文件能提取。
   CI 的 `install-slices` 检查这个。
2. **可用性** —— `chroot` 进切出来的 rootfs 真的把命令跑起来。spread 测这个。

测试里的常用套路：

```bash
rootfs="$(install-slices tcpdump_bins)"      # 切一个新 rootfs，返回路径
chroot "${rootfs}" /usr/bin/tcpdump --version
```

约定与坑：

- **每个测试用独立的 rootfs**。如果几个测试共用一个，前面测试装进来的依赖会
  掩盖后面测试缺的依赖。reviewer 一定会提这一点。
- **`bins` 切片里声明的每个二进制都得被跑到**，`check-test.py` 会检查覆盖率。
  实在没法完整驱动的，至少要跑起来 grep 一下它自己的 usage 文本，证明动态链接
  能解析。
- 切出来的 rootfs 极简，没有 `/dev/null`、没有 `/bin/sh`。需要就自己造：
  `mkdir -p "${rootfs}/dev" && touch "${rootfs}/dev/null"`。
- **不要 `cmd | grep -q`**。`grep -q` 匹配到就退出并关闭管道，上游命令收到
  SIGPIPE 挂掉，配合 `pipefail` 整条流水线就失败了。我在 bridge-utils 上踩过：
  `brctl show | grep -q` 一直失败。正确写法是先存变量：
  ```bash
  out="$(chroot "${rootfs}" cmd)"
  echo "${out}" | grep -Fq "..."
  ```
- **spread 用 `set -x` 跑 task**，xtrace 输出走 stderr。所以 `2>&1` 会把
  `+ chroot ...` 这种行也抓进变量。用 `grep` 无所谓，但如果要断言"输出为空"
  （`test -z`），必须只抓 stdout。arping 的 `-q` 测试就是这么修的。
- 断言统一用 `grep -Fq`（`-F` 按字面量、`-q` 静默），需要正则才用 `-E`。
- 尽量**自给自足**：自己造输入文件、自己造假的 sysfs 树，不要依赖宿主机有什么
  硬件、不要 apt 装额外东西。这样在 CI 的 6 个架构上行为一致。

### 我用的验证流程

所有验证都在一台 Ubuntu 26.04 的 multipass 虚拟机里做（mason 的脚本和 spread
只能在 Ubuntu 上跑）。每个包一个独立的 git worktree，互不干扰。

提 PR 前每个包都跑过这些：

```bash
yamllint -c .github/yamllint.yaml chisel.yaml slices/   # CI 的 lint
yq ... | sort -C                                        # CI 的排序检查
validate_hints.py slices/x.yaml                         # CI 的 hint 词法检查
check-slice.py slices/x.yaml                            # mason 的 SDF linter
check-test.py  slices/x.yaml                            # 测试覆盖率检查
check-diff.py --base upstream/ubuntu-26.04              # 只增不删检查
spread lxd:tests/spread/integration/x                   # 集成测试
```
