# PR #8 Review Context — Resolute Migration

> **此文件不提交 Git，仅供多 session review 上下文传递。**

## 1. 任务描述

Review PR #8: https://github.com/canonical/sonic-buildimage/pull/8

- **源分支**: `202605_resolute_real`
- **目标分支**: `202605_resolute_mech`
- **目的**: 将 SONiC 202605 构建链从 Debian Trixie 迁移为 Ubuntu Resolute (26.04)
- **叠加关系**: PR #8 叠加在 PR #7 之上

## 2. Review 原则（用户明确）

1. **平台范围**: 仅需让 Resolute SONiC 在 **vs** 和 **broadcom** 上跑起来。其他平台 (cisco, mellanox, marvell 等) 的 enablement 不应在本 PR 完成。
2. **最小改动**: 尽量减少不必要的修改，控制工作 scope。
3. **单一 base OS**: 此分支仅需要构建 Resolute based SONiC，不需要从中构建基于其他 base OS 的 SONiC。
4. **简化 BLDENV 分支**: 基于原则 3，尽可能减少 Makefile 中对 BLDENV 判断分支的复杂度。但出于原则 2，现有的 trixie 路径无需移除。
5. **仅提 review comment**: 本工作仅给 PR 提 review comment，由负责该 PR 的同事修复和测试，不亲自修问题。
6. **不改本地代码**: 不对本地代码做改动；即使有改动也仅限测试性目的，绝不提交 commit。
7. **交互语言**: 尽量用中文跟我对话和叙述思考过程，软件包名、Ubuntu / Debian 发行版名、计算机名词术语可保留英文
8. **会话命名**: Code Agent 的会话，只要 Prompt 中明确指出阅读此文档且 Review PR 的，该会话的标题就应该是 “PR#8 Review - xxxx” 的形式
9. **着眼整体**: 不要逐个 commit 去分析，因为可能会有多个 commits 是出于同一目的，而有的 commit 的改动在之后被 revert 掉了，因此分析目标是 source branch 和 target branch 之间所有待合并 commits squash 后的整体修改

## 3. 迁移背景

### 设计与计划文档

文档在 `202605_resolute_doc` 分支的 `docs/superpowers/` 目录下（仅在 doc 分支，不在工作分支）：

| 文档 | 内容 |
|------|------|
| `specs/2026-07-03-sonic-202605-resolute-migration-design-en.md` | 迁移设计（Approach A，5 阶段，pivot table） |
| `plans/2026-07-03-sonic-202605-resolute-migration-plan-en.md` | 实现计划（19 个 Task） |
| `resolute-modification-catalog-en.md` | 修改目录（12 个主题，70 commits 的归类） |
| `resolute-vs-migration-report-en.md` | VS 迁移报告（7 类工具链差异，逐包修复） |
| `resolute-migration-code-review-en.md` | 代码审查（defect view，未 fetch） |

### 原始设计要点

- **Approach A**: 新增 `BLDENV=resolute`，作为默认且唯一启用的 BLDENV
- **原始目标**: 仅 vs（虚拟交换机）；done-bar = vs 镜像 KVM 启动 + smoke 通过
- **实际范围**: 扩展到 broadcom（`sonic-broadcom.bin` 也构建成功）
- **5 个阶段**: slave → host OS → container base → vs containers → assemble+boot

### 7 类工具链差异（Trixie → Resolute）

| # | 差异 | 示例 |
|---|------|------|
| 1 | dpkg 解析更严格 (dpkg 1.23) | Maintainer 字段、changelog trailer |
| 2 | GCC 15 / C23 | `-Werror=conversion`、`bool` 关键字 |
| 3 | C++17 + libstdc++ 15 | gtest 要求 C++17、`std::iterator` 弃用 |
| 4 | LTO 误报 | `-flto=auto` 下 `maybe-uninitialized` |
| 5 | doxygen 1.15.0 | `<ref>` autolink 破坏 SAI parse.pl |
| 6 | boost 默认 1.90 (header-only) | `libboost_system.so` 消失；slave 最终锁定 **1.83** |
| 7 | Python 3.14 / 包重命名 | `pkgutil.get_loader` 移除、SWIG 4.4 `$function` |

## 4. PR #7 与 PR #8 的边界

### PR #7 — mechanical

https://github.com/canonical/sonic-buildimage/pull/7

纯机械重命名：trixie → resolute。创建 resolute 命名的 variant chain：
- `dockers/docker-base-resolute/` (from trixie)
- `dockers/docker-config-engine-resolute/` (from trixie)
- `dockers/docker-swss-layer-resolute/` (from trixie)
- 90 个文件中 `ARG BASE` 的 `trixie` → `resolute`
- `rules/*.mk` 中 `SONIC_TRIXIE_DOCKERS` → `SONIC_RESOLUTE_DOCKERS` 等
- 220 insertions / 220 deletions（纯替换）

**注意**: trixie 目录（`dockers/docker-base-trixie/` 等）和 trixie slave（`sonic-slave-trixie/`）**仍然保留**在仓库中，未被删除。

### PR #8 — real changes
https://github.com/canonical/sonic-buildimage/pull/8

## 5. 初始发现

### 5.1 BLDENV 分支复杂度（对应原则 3、4）

**Makefile** — trixie/bookworm 路径保留但默认禁用:
```makefile
NOBOOKWORM ?= 1    # 改为 1（原为 0）
NOTRIXIE ?= 1      # 改为 1（原为 0）
NORESOLUTE ?= 0     # 新增

ifeq ($(NORESOLUTE),0)
BUILD_RESOLUTE=1
endif
# ...
# catch-all default → BLDENV=resolute
# docker-cleanup → BLDENV=resolute
```
- bookworm/trixie 仍保留 `BUILD_BOOKWORM`/`BUILD_TRIXIE` 块和底部分发行
- **问题**: 既然此分支只构建 resolute，trixie/bookworm 的 NO* 变量和分发逻辑是否可以移除以简化？

**Makefile.work** — SLAVE_DIR 保留 trixie:
```makefile
ifeq ($(BLDENV), resolute)
SLAVE_DIR = sonic-slave-resolute
else ifeq ($(BLDENV), trixie)    # 保留
SLAVE_DIR = sonic-slave-trixie
else ifeq ($(BLDENV), bookworm)  # 保留
...
```

**slave.mk** — resolute 分支用 `filter-out` 排除 trixie base images:
```makefile
# 行 1272-1275
else ifeq ($(BLDENV),resolute)
    # Exclude the trixie base images: all dockers use the resolute base chain.
    DOCKER_IMAGES = $(filter-out $(DOCKER_BASE_TRIXIE) $(DOCKER_CONFIG_ENGINE_TRIXIE) $(DOCKER_SWSS_LAYER_TRIXIE),$(SONIC_DOCKER_IMAGES))
    DOCKER_DBG_IMAGES = $(filter-out ...)
```
- **问题**: 这是因为 trixie base 目录仍存在且仍注册在 `SONIC_DOCKER_IMAGES` 中，resolute 分支需要排除它们。如果 trixie base images 被彻底移除，这个 filter-out 就不需要了。

**slave.mk** — ENABLE_PY2 filter:
```makefile
# 行 81
ifneq ($(filter bullseye bookworm trixie resolute,$(BLDENV)),)
```

**slave.mk** — 其他 resolute 特定改动:
- 行 1014: `--force-depends` for platform/platform-modules debs（resolute 特有，注释说明内核模块在此阶段未安装）
- 行 1503: RFS prerequisites 列出 split grub2 debs（Ubuntu 拆分 grub2）
- 行 1576, 1625: 移除 `LINUX_KBUILD`（Ubuntu linux-sonic 无 kbuild deb）

### 5.2 平台范围（对应原则 1）

**符合范围的改动**:
- `platform/broadcom/` — broadcom 平台（one-image.mk, rules.dep, rules.mk, sai-modules.mk, saibcm-modules 子模块, dell 平台模块, sswsyncd）
- `platform/pddf/i2c/` — PDDF I2C 平台模块（可能是 broadcom 相关）
- `platform/vpp` — 子模块指针更新

**未发现其他平台改动**: 无 cisco, mellanox, marvell, barefoot 等平台的改动（符合范围）

### 5.3 可能超出范围的改动（需进一步审查）

| Commit / 文件 | 关注点 |
|---------------|--------|
| `d3125f835` resolv.conf 直接渲染 | 运行时修复，非构建修复。是否是 resolute 必需？还是通用 SONiC 修复？ |
| `1ac4c2739` rsyslogd AppArmor | 运行时修复。是否 resolute 特有（AppArmor 行为差异）？ |
| `rules/flashrom.mk` | 改为 stock Ubuntu online deb（原源码构建）。de-fork 是否必要？ |
| `rules/sedutil.mk` | 同上，改为 stock Ubuntu deb |
| `rules/sonic-fips.mk` | trixie/resolute 合并为 `$(filter ...)` — 合理 |
| `src/sonic-frr/Makefile` | LTO off + git reset --hard unconditional |
| `src/isc-dhcp/` | 新增 udeb sbin 目录 patch |
| `src/monit/` | patch series 变化 |

### 5.4 子模块 retargeting（`.gitmodules` + gitlinks）

15 个子模块 URL 从 `sonic-net/` 改为 `canonical/`:
```
sonic-swss-common, sonic-sairedis, sonic-swss, sonic-snmpagent,
sonic-utilities, sonic-mgmt-framework, sonic-mgmt-common,
wpasupplicant/sonic-wpa-supplicant, dhcprelay, sonic-gnmi,
sonic-bmp, sonic-dash-api, sonic-dash-ha, sonic-stp,
platform/vpp, platform/broadcom/saibcm-modules (branch: 202605_resolute)
```
- 这些是 Canonical fork 上带工具链修复的 commit
- 需验证所有 gitlink commit 是否已推送到 `canonical/<submodule>:202605_resolute`

注意： 子模块 sonic-linux-kernel 在 PR 中可能已经不再被使用

### 5.5 sonic-slave-resolute/Dockerfile.j2（87 行改动，核心文件）

关键改动（基于修改目录文档）:
- `FROM ubuntu:resolute`
- boost 锁定 **1.83**（18 行 `1.88-dev` → `1.83-dev`）
- Dh_Lib.pm `ddeb` → `deb`（dbgsym 单点修复）
- 全局 buildflags: `-std=gnu17` + 放宽 GCC15 `-Werror`
- thrift → 0.22.0, Pillow 源码构建加 libjpeg-dev
- kernel build deps: lz4, gcc-14, kernel-wedge, python3-dacite
- FIPS Go 从 `fips/trixie/` 路径下载

### 5.6 关键源码包改动

| 包 | 改动类型 | 说明 |
|----|----------|------|
| bash | 5.2→5.3, patch rebase | 200 行 patch 变化（plugin support） |
| grub2 | 2.06→2.14, Ubuntu split | 新增 `src/grub2-unsigned/`, overlayfs ln patch |
| libnl3 | 3.7→3.12, alias 方式 | `add-nh_id-aliases.sh` 注入 API 别名 |
| libyang3 | 3.12→3.13.6 | re-enable pr2362 patch |
| socat | 1.7.4→1.8.1.1 | `_FORTIFY_SOURCE=3` strchr const 修复 |
| linux-kernel | procure 预构建 | `linux-sonic 7.0.0-1002` via SONIC_ONLINE_DEBS |
| sonic-frr | LTO off | `DEB_CFLAGS_MAINT_STRIP=-flto=auto` |
| isc-dhcp | LTO off + udeb mkdir | |

## 6. PR Review 历史

已由 3 位 reviewer 审查：
- **henrymao-zz**
- **jy5275**
- **benhoyt**

多个 review 驱动的后续 commit 已合入

## 7. 待审查问题清单

### 高优先级

1. **BLDENV 分支简化**: trixie/bookworm 的 NO* 变量、BUILD_* 块、SLAVE_DIR 分支、ENABLE_PY2 filter 是否可以移除？slave.mk 的 `filter-out` trixie base images 是否可以通过删除 trixie base 目录来消除？
2. **运行时修复的必要性**: `d3125f835` (resolv.conf) 和 `1ac4c2739` (rsyslogd AppArmor) 是否是 resolute 迁移必需？还是通用 SONiC 修复（应该在 upstream PR 中提）？
3. **de-fork 的合理性** (`2a324511b`): flashrom/sedutil 等从源码构建改为 stock Ubuntu deb，是否有功能损失？
4. **子模块 gitlink 可达性**: 所有 canonical fork 的 commit 是否已推送到远端？
5. **broadcom 改动的完整性**: dell 平台模块的 C 代码改动（mc24lc64t.c, fpga_gpio.c 等）是否仅是 Linux 7.0 API 适配，无功能变化？

### 中优先级

6. sonic-slave-resolute/Dockerfile.j2 的 Dh_Lib.pm sed patch 是否健壮（幂等性）？
7. `--force-depends` 对 platform-modules 的注释是否准确？
8. grub2 Ubuntu split 的 `patch-overlayfs-ln.sh` 是否被 git track（`.gitignore` 忽略 `*`）？
9. libnl3 alias 方案 vs 上游 swss 改用 `rtnl_route_get_nhid` — 技术债是否记录？
10. bash 5.3 plugin patch 的 200 行 diff 是否仅是 context rebase？

### 低优先级

11. AGENTS.md 新增（174 行）— 内容是否准确、是否与 doc 分支重复？
12. `scripts/submodule-ff-audit.sh` 新增（129 行）— 工具脚本，是否在 scope 内？
13. 注释规范（`c305ee2e8`）— 是否有过度注释或注释不足？

## 8. 快速参考

### 本地仓库状态

- **工作目录**: `/home/ubuntu/repos/sonic-buildimage`
- **当前分支**: `202605_resolute_real`
- **remote**: `origin = https://github.com/canonical/sonic-buildimage.git`
- **工作区**: 有少量 untracked 文件（`.opencode/`, justfiles, build 残留），无 tracked 文件改动

### 常用命令

```bash
# 查看 PR #8 的完整 diff（相对于 PR #7 base）
git diff 6f2882cce..d3125f835 -- <path>

# 查看单个 commit
git show <commit> -- <path>

# 查看某文件在 PR #8 中的改动
git diff 6f2882cce..d3125f835 -- <file>

# 查看 PR #7 (mechanical) 的改动
git diff daae5058f..6f2882cce --stat

# 查看 AGENTS.md（仓库根目录，已含迁移指南）
cat AGENTS.md
```

### 关键文件清单

| 文件 | 改动量 | 说明 |
|------|--------|------|
| `sonic-slave-resolute/Dockerfile.j2` | 87 行 | slave 构建容器（工具链、apt、dbgsym patch） |
| `src/bash/patches/0001-Add-plugin-support-to-bash.patch` | 200 行 | bash 5.3 plugin patch rebase |
| `rules/libnl3.mk` | 94 行 | libnl3 alias 方案 |
| `rules/linux-kernel.mk` | 66 行 | procure 预构建内核 |
| `rules/grub2.mk` | 55 行 | grub2 Ubuntu split |
| `build_debian.sh` | 54 行 | docker 版本、apt 源、resolv.conf |
| `platform/broadcom/rules.mk` | 48 行 | broadcom 平台规则 |
| `rules/linux-kernel.dep` | 24 行 | 内核依赖 |
| `.gitmodules` | 34 行 | 15 个子模块 URL retarget |
| `slave.mk` | 22 行 | BLDENV=resolute 构建图接入 |
| `AGENTS.md` | 174 行（新增） | AI 模型指南 |
| `files/build_templates/sonic_debian_extension.j2` | 29 行 | pip/lxml/pkgutil 运行时修复 |
| `scripts/submodule-ff-audit.sh` | 129 行（新增） | 子模块 FF 审计工具 |

### 迁移文档链接（`202605_resolute_doc` 分支）

- 设计: https://github.com/canonical/sonic-buildimage/blob/202605_resolute_doc/docs/superpowers/specs/2026-07-03-sonic-202605-resolute-migration-design-en.md
- 计划: https://github.com/canonical/sonic-buildimage/blob/202605_resolute_doc/docs/superpowers/plans/2026-07-03-sonic-202605-resolute-migration-plan-en.md
- 修改目录: https://github.com/canonical/sonic-buildimage/blob/202605_resolute_doc/docs/superpowers/resolute-modification-catalog-en.md
- VS 报告: https://github.com/canonical/sonic-buildimage/blob/202605_resolute_doc/docs/superpowers/resolute-vs-migration-report-en.md
- 代码审查: https://github.com/canonical/sonic-buildimage/blob/202605_resolute_doc/docs/superpowers/resolute-migration-code-review-en.md（**尚未 fetch**）
