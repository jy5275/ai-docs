# Resolute SONiC 基础 CI 流水线设计

日期：2026-09-04
状态：设计定稿，待实现
关联仓库：https://github.com/canonical/sonic-buildimage
目标分支：`202605_resolute`

## 1. 背景与目标

Noble 时代的 CI（`feature_noble_build` 分支的 `.github/workflows/run_testbed.yml` +
`.github/testflinger/*.yaml`）依赖 Canonical 内部 Testflinger 机器做实际构建：GitHub
workflow 只负责生成 job YAML、提交并轮询。该链路问题为：多一层基础设施依赖、反馈慢、
Testflinger 队列不可控。

本设计的目标：去掉 Testflinger 层，在带 `[resolute, amd64, large]` label 的
self-hosted GitHub Actions runner（8 CPU / 32 GiB / 100 GiB，临时 VM、每次重置）上直接
跑 Resolute SONiC 构建，达成：

1. 验证 `target/sonic-vs.img.gz`（PLATFORM=vs）构建成功。
2. 验证 `target/sonic-broadcom.bin`（PLATFORM=broadcom）构建成功。
3. 设计需确保 broadcom 产物面向 `x86_64-dellemc_s5232f_c3538-r0` 硬件可用（“可安装运行”），
   但 **CI 不添加任何验证该目标的步骤**——只构建、不装机、不跑测试用例。

仅作参考、不盲从的文件：

- `run_testbed.yml`（noble 时代 runner 侧流程）
- `.github/testflinger/build_brcm_on_feature_noble_build.yaml`（构建命令来源）

## 2. 关键决策

| 决策点 | 结论 | 理由 / 备注 |
|---|---|---|
| 构建目标 | vs + broadcom 两个 platform target | 基础 CI 范围 |
| 触发 | `merge_group` (checks_requested) + `workflow_dispatch` | 不在 PR 每次 push 构建；merge queue 保证最新合成 SHA 必绿才合入 |
| PR 期间反馈 | 入队才跑，PR 打开不自动跑 | 单次构建代价高；后续可加轻量检查 |
| job 拆分 | 拆成 test 与 build 两层：test（构建全部 deb/wheel + 内嵌单测）→ gate [build-vs, build-broadcom] 并行 | 单测无法脱离包构建单独运行（见 §4.2）；拆开使每个 job 峰值盘/内存低于单一大 job |
| 测试构建开关 | test job `BUILD_SKIP_TEST` 不设（默认跑）；build job = y | build job 省时省盘；测试复用 test job |
| 缓存 | 本阶段不做跨 job 构建缓存 | 临时 VM；跨 job deb 缓存复用（见 §7.1）留作后续迭代 |
| runs-on | `[self-hosted, resolute, amd64, large]` | label 只支持 AND；large/xlarge OR 需 runner group，留升级路径（见 §7） |
| 构建镜像源 | 默认源（不设 MIRROR_URLS） | 标准优先 |
| 超时 / 重试 | job 720min；`SONIC_BUILD_RETRY_COUNT=3` | 冷构建预算 |
| 并行度 / 内存 | `SONIC_BUILD_JOBS=4`；`SONIC_BUILD_MEMORY=24g`（写入 rules/config.user） | 32G 主机 README 参考值 |
| 产物 | vs/broadcom 两个 image 上传 GitHub artifacts，保留 7 天 | 后续可按需接装机流程 |
| 前置依赖 | workflow 内自行安装（docker-ce + docker-buildx-plugin + jinjanator 等） | runner 可能换镜像，自包含更稳 |

## 3. Workflow 结构

文件：`.github/workflows/resolute-build.yml`，提交于 `202605_resolute` 分支
（触发分支上必须存在该文件）。

```yaml
name: resolute-build
on:
  merge_group:
    branches: [202605_resolute]
    types: [checks_requested]
  workflow_dispatch:
    inputs:
      ref:
        description: 要构建的 ref（默认 202605_resolute）
        default: 202605_resolute

concurrency:
  group: resolute-build-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test-vs:         # 平台无关包全集构建 + 内嵌单测（PLATFORM=vs）
  build-vs:        # needs: test-vs；BUILD_SKIP_TEST=y；target/sonic-vs.img.gz
  build-broadcom:  # needs: test-vs；BUILD_SKIP_TEST=y；target/sonic-broadcom.bin
```

- 三个 job `runs-on: [self-hosted, resolute, amd64, large]`；注释说明可切换 runner group。
- `build-vs` 与 `build-broadcom` 并行，各占一台 runner。
- `workflow_dispatch` 用于 merge queue 之外的手动验证（对指定 ref）。
- merge queue 需在仓库 branch protection 开启 “Require merge queue”，
  并把本 workflow 的 job 设为 required check（实现细节见实施计划）。

`concurrency` 段落含义：保证同一时刻最多一个同 group 值的 run 在执行；
`cancel-in-progress: true` 表示新 run 到达时直接取消进行中的旧 run（而非排队等待）。
在本 workflow 中的实际效果：

- dispatch 对同一 `ref` 重复提交时，旧 run 被取消，昂贵构建不会叠加。
- merge queue 每次入队产生新的合成 ref（`refs/heads/gh-readonly-queue/...`），
  不同入队尝试属于不同 group、互不取消——每次入队都独立完整地跑，符合预期。

## 4. Job 实现细节

### 4.1 共用 setup（三个 job 一致，幂等）

1. `actions/checkout@v4`：`fetch-depth: 0`，`submodules: recursive`
   （merge_group 合成 ref 是 HEAD，直接 checkout）。
2. 安装前置：docker-ce、containerd.io、`docker-buildx-plugin`、jq、make、git、
   python3-pip；runner 用户安装 jinjanator；`sudo modprobe overlay`；runner 用户加入
   docker 组或经 sudo 执行 docker。
   - **必须显式安装 docker-buildx-plugin**：实测 docker-ce 29 不装 buildx 会退回
     legacy builder，无 BuildKit GC，中间层全部沉淀（24G 数据实测 ≈ 47G 磁盘）。
3. 写入 `rules/config.user`（gitignored）：
   ```
   SONIC_BUILD_MEMORY = 24g
   ```
4. `df -h` + `docker system df` 水位记录（构建前后）。
5. daemon.json 保持默认：BuildKit GC docker driver 默认策略（GC enabled，
   keepStorage 20GB）已足够。GC 不降低单次构建峰值，100G 预算靠控制构建规模满足。

### 4.2 test-vs job

```bash
make init
make configure PLATFORM=vs
# 枚举该配置下全部 deb + wheel 包（实测格式：一行一个 target 路径）
make $(make list | grep -E '^target/(debs|python-wheels)/')
```

- 不设置 `BUILD_SKIP_TEST` → 包构建 recipe 内嵌单测照常运行（本 fork 无独立 tests
  target；测试内嵌在包构建里，见 `slave.mk`）。
- 不构建 docker 镜像、rootfs、installer（本 job 的磁盘峰值明显低于 build job）。
- 已知噪音：`make` parse 阶段有 j2 渲染、versions-web 网络校验、sonic-build-hooks
  打包等输出，属正常现象；网络不可达时自动降级，不阻断。
- 失败时收集 `target/debs/**/*.log`、`target/python-wheels/**/*.log` 上传。

### 4.3 build-vs / build-broadcom

```bash
make init
make configure PLATFORM=<vs|broadcom>
BUILD_SKIP_TEST=y make SONIC_BUILD_JOBS=4 target/sonic-vs.img.gz   # build-vs
BUILD_SKIP_TEST=y make SONIC_BUILD_JOBS=4 target/sonic-broadcom.bin # build-broadcom
```

- 删除构建成功后的临时中间产物（`rfs.squashfs` 等）以预留 artifact 传输盘余量（可选）。
- 成功：上传 `target/sonic-vs.img.gz` / `target/sonic-broadcom.bin` 为 artifact，
  retention-days: 7。
- 失败：打包上传 `target/*.log`、关键包构建日志。

### 4.4 环境假设（写入文档，违反则需 rework）

- runner 操作系统为 Ubuntu Resolute（由 `resolute` label 定义保证），passwordless
  sudo。
- runner 网络可达 github.com（checkout/submodule）、docker 官方源、
  archive.ubuntu.com。
- 临时 VM：每次 job 干净的 /var/lib/docker（及 /var/lib/containerd，若引擎启用
  containerd image store）。

## 5. 磁盘与资源预算（100 GiB 验收依据）

| 项目 | 估算 | 依据 |
|---|---|---|
| 系统 + runner 基础 | ~10G | 经验值 |
| 源码 + submodules checkout | ~5-8G | 实测 src/ 3.9G + .git |
| sonic-slave 镜像（1-2 个变体） | ~16-32G | 实测 15.8G ×2 |
| 包构建中间产物 + target/debs | ~15-25G | README 参考 + 实测 target 7.4G |
| docker 镜像层（完整 build 链） | ~20-40G | 实测含 pruned 后 42G |
| rfs 拷贝 + squashfs + 最终 bin | ~8G | 实测 bin 2.1G + squashfs 1.4G + rootfs 2.8G |
| dbg 镜像 | 0（不构建） | 设计排除 |

合计峰值 ~90-100G，处于 100G 上限制上沿但可接受；三个 job 中 build-broadcom 最重。
风险缓解顺序：buildkit GC 默认、不建 dbg、BUILD_SKIP_TEST=y（build job）、
`SONIC_BUILD_JOBS=4`、需要时 `make clean-docker`。

## 6. 验证与上线检查

1. workflow 文件合并进 `202605_resolute` 后，用 `workflow_dispatch` 手动全量验证三
   job 一次（冷构建预算 ~3-6h）。
2. 观察 `df` 峰值余量是否足够；不足则回到 §5 缓解顺序调整。
3. 开启 branch protection：Require merge queue + required checks 指向本 workflow。
4. 试跑一次 merge queue 全流程（PR → 入队 → 自动合并）。

## 7. 已记录、暂不实施的迭代项

1. **跨 job deb 缓存复用**：让 build job 复用 test job 已验证过的同一批 deb 产物，
   避免重复编译。实现方式：test job 以 `SONIC_DPKG_CACHE_METHOD=wcache` +
   `SONIC_DPKG_CACHE_SOURCE` 把各包缓存写入目录（框架已内置，见 `Makefile.cache`，
   SHA 依赖追踪），经 GitHub artifact 传给 build job，后者以 `rcache` 模式恢复后
   复用，跳过重复编译。总耗时可由 ~2× 降至 ~1.3×；代价是 CI 胶水层复杂度（cache
   一致性、几 GB 传输、静默 miss 排查）与首轮验证成本。若日后全流程耗时不可接受，
   按此启用。
2. **runner group 化**：`[resolute, amd64, large]` → `runs-on: {group: <包含 large
   与 xlarge 的组>, labels: [resolute, amd64]}`，解除对 large 单型号的绑定。
3. **PR 期轻量反馈**：lint/语义检查等廉价 job 挂在 pull_request 上。
4. **broadcom 硬件可用性验证**：如 future 需要，可在 squashfs 内容层做
   x86_64-dellemc_s5232f_c3538-r0 platform 工件存在性校验。当前范围内明确不做
   （见 §1 目标 3：CI 只构建、不验证硬件目标）。