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
| job 结构 | 两个独立 job `build-vs` / `build-broadcom`，互不依赖、并发执行，各自构建目标 platform 的全部包并直构 target | 单测只能内嵌在包构建里跑（见 §4）；曾设 test/building 两层拆分（§6.2 修订），因 test-vs 全包构建耗时过长且与 build job 重复，2026-09-05 取消 |
| 测试开关 | 不设置 `BUILD_SKIP_TEST`，构建时运行内嵌单测 | 两个 build job 一致 |
| 缓存 | 本阶段不做跨 job 构建缓存 | 临时 VM；跨 job deb 缓存复用（见 §7.1）留作后续迭代 |
| runs-on | `[self-hosted, resolute, amd64, large]`；两 job 并行各占一台 runner | label 只支持 AND；large/xlarge OR 需 runner group，留升级路径（见 §7） |
| 构建镜像源 | 默认源（不设 MIRROR_URLS） | 标准优先 |
| 超时 / 重试 | job 720min；`SONIC_BUILD_RETRY_COUNT=3` | 冷构建预算 |
| 并行度 / 内存 | `SONIC_BUILD_JOBS=4`；`SONIC_BUILD_MEMORY=24g`（写入 rules/config.user） | 32G 主机 README 参考值 |
| 产物 | vs/broadcom 两个 image 上传 GitHub artifacts，保留 7 天 | 后续可按需接装机流程 |
| 前置依赖 | workflow 内自行安装（docker-ce + docker-buildx-plugin + jinjanator 等），**docker 已存在但 buildx 缺失时单独补装 buildx** | runner 可能换镜像，自包含更稳；干跑实测 runner 预装 docker 无 buildx（§6.2 修订） |

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
        description: Build ref (branch or tag)
        default: 202605_resolute

concurrency:
  group: resolute-build-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-vs:        # 全部包构建（默认跑内嵌单测）+ target/sonic-vs.img.gz
  build-broadcom:  # 全部包构建（默认跑内嵌单测）+ target/sonic-broadcom.bin
```

- 两个 job `runs-on: [self-hosted, resolute, amd64, large]`，互不依赖、并行执行，
  各占一台 runner；注释说明可切换 runner group。
- `workflow_dispatch` 用于 merge queue 之外的手动验证（对指定 ref）。
- merge queue 需在仓库 branch protection 开启 “Require merge queue”，
  并把本 workflow 的两个 job 设为 required check（实现细节见实施计划）。

`concurrency` 段落含义：保证同一时刻最多一个同 group 值的 run 在执行；
`cancel-in-progress: true` 表示新 run 到达时直接取消进行中的旧 run（而非排队等待）。
在本 workflow 中的实际效果：

- dispatch 对同一 `ref` 重复提交时，旧 run 被取消，昂贵构建不会叠加。
- merge queue 每次入队产生新的合成 ref（`refs/heads/gh-readonly-queue/...`），
  不同入队尝试属于不同 group、互不取消——每次入队都独立完整地跑，符合预期。

## 4. Job 实现细节

### 4.1 共用 setup（两个 job 一致，幂等）

1. `actions/checkout@v4`：`fetch-depth: 0`，`submodules: recursive`
   （merge_group 合成 ref 是 HEAD，直接 checkout）。
2. 安装前置（复合动作 `install-prerequisites.sh`，经
   `bash ${{ github.action_path }}/install-prerequisites.sh` 引用）：docker-ce、
   containerd.io、`docker-buildx-plugin`、jq、make、git、python3-pip；runner 用户安装
   jinjanator；`sudo modprobe overlay`；runner 用户加入 docker 组或经 sudo 执行 docker。
   - **必须显式安装 docker-buildx-plugin**：实测 docker-ce 29 不装 buildx 会退回
     legacy builder，无 BuildKit GC，中间层全部沉淀（24G 数据实测 ≈ 47G 磁盘）。
   - **docker 已预装但 buildx 缺失时必须补装**（§6.2 干跑实测：runner 预装
     docker-ce 29.1.3 而无 buildx plugin）：先试 Ubuntu 仓库 `docker-buildx`，不可用再
     加 docker.com 仓装 `docker-buildx-plugin`；两条路都失败只告警不失败。
3. 写入 `rules/config.user`（gitignored）：
   ```
   SONIC_BUILD_MEMORY = 24g
   ```
4. `df -h` + `docker system df` 水位记录（构建前后）。
5. daemon.json 保持默认：BuildKit GC docker driver 默认策略（GC enabled，
   keepStorage 20GB）已足够。GC 不降低单次构建峰值，100G 预算靠控制构建规模满足。

### 4.2 build-vs / build-broadcom

（2026-09-05 修订：原 test-vs job 取消，其职责并入两个 build job，见 §6.2。）

```bash
make init
make configure PLATFORM=<vs|broadcom>
make target/sonic-vs.img.gz      # build-vs
make target/sonic-broadcom.bin   # build-broadcom
```

- 不设置 `BUILD_SKIP_TEST` → target 依赖的全部 deb/wheel 包构建时内嵌单测照常
  运行（本 fork 无独立 tests target；测试内嵌在包构建里，见 `slave.mk`）。
- 两个 job 互不依赖（无 `needs`），由同一 workflow run 并行派发。
- 已知噪音：`make` parse 阶段有 j2 渲染、versions-web 网络校验、sonic-build-hooks
  打包等输出，属正常现象；网络不可达时自动降级，不阻断。
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

合计峰值 ~90-100G，处于 100G 上限制上沿但可接受；两个 job 并行，各自独立占满
预算，build-broadcom 最重。
风险缓解顺序：buildkit GC 默认、不建 dbg、`SONIC_BUILD_JOBS=4`、需要时
`make clean-docker`。（注：2026-09-05 起两 job 均默认跑内嵌单测，
BUILD_SKIP_TEST 不再作为缓解手段。）

## 6. 验证与上线检查

1. workflow 文件合并进 `202605_resolute` 后，用 `workflow_dispatch` 手动全量验证两
   job 一次（冷构建预算 ~2.5-5h/job，并行计最大者）。
2. 观察 `df` 峰值余量是否足够；不足则回到 §5 缓解顺序调整。
3. 开启 branch protection：Require merge queue + required checks 指向本 workflow。
4. 试跑一次 merge queue 全流程（PR → 入队 → 自动合并）。

### 6.2 修订记录（2026-09-04 第一次干跑后）

干跑 run 33855288953（`ci-workflow/resolute-dryrun`）发现两处与假设不符：

1. **buildx 缺失**：runner 预装 docker-ce 29.1.3，但 `docker buildx version` 报
   `unknown command: docker buildx` — 注意 29.1.3 与 canonical runner 镜像一致，
   说明 runner 模板只装 docker 不装 buildx plugin。由于 composite action 只在
   "docker 不存在"时安装，buildx 被漏过，触发 legacy builder 风险（§4.1 约束）。
   修订：§4.1 新增 buildx 补装分支（docker 已存在但无 buildx 时先试 Ubuntu
   `docker-buildx`，再回退 docker.com 仓；两条路都失败只 WARN 并清理落盘源文件）。
   r2（33884212829）验证生效：buildx 0.30.1、无 WARN。
2. **Configure 步骤日志噪音**：test-vs 全日志 5.7MB/33757 行，其中 Configure
   步骤 22774 行（67%）；`W: Target Packages ... configured multiple times` 6304 行
   （host sources.list 与 ubuntu.sources 重复注册）+ dpkg 进度类 ~5100 行。
   GitHub job 页对此类日志渲染内存 >1G。
   曾实现一轮降噪方案（apt 源去重步骤 + tee/正则过滤管道 + 失败日志并入），
   **用户 2026-09-05 评估后判定 over-engineering，全部撤销**；此问题仅在此登记，
   列 §7 迭代项，后续另立设计方案再做。
3. **job 结构改为双 build**（用户 2026-09-05）：test-vs 全包构建+单测耗时过长且
   与后续 build job 工作重复，取消该 job；build-vs / build-broadcom 互不依赖并发，
   均默认跑内嵌单测。代价：单测与产物同 job（峰值盘保持 §5 预算）；需要 ≥2 台
   `[resolute, amd64, large]` runner 才能真并发（干跑观察确认）。§2/§3/§4.2/§5 同步
   修订，required check context 变为两个 job 名。

## 7. 已记录、暂不实施的迭代项

1. **跨 job deb 缓存复用**：当前两 build job 并发且互不依赖，不存在生产者/消费者
   关系；若未来恢复依赖链或引入独立的包构建 job，可由前序 job 以
   `SONIC_DPKG_CACHE_METHOD=wcache` + `SONIC_DPKG_CACHE_SOURCE` 把各包缓存写入目录
   （框架已内置，见 `Makefile.cache`，SHA 依赖追踪），经 GitHub artifact 传给后继
   job，后者以 `rcache` 模式恢复后复用，跳过重复编译。代价是 CI 胶水层复杂度
   （cache 一致性、几 GB 传输、静默 miss 排查）与首轮验证成本。
2. **CI 日志体积治理**：Configure 步骤实测 22774 行且半数为 apt/dpkg 噪音（§6.2），
   GitHub job 页渲染内存 >1G。曾实现 apt 源去重 + 输出过滤方案，用户判定
   over-engineering 后撤销；重新设计时以「源头修复优先、最小侵入」为原则单独立项。
3. **runner group 化**：`[resolute, amd64, large]` → `runs-on: {group: <包含 large
   与 xlarge 的组>, labels: [resolute, amd64]}`，解除对 large 单型号的绑定。
4. **PR 期轻量反馈**：lint/语义检查等廉价 job 挂在 pull_request 上。
5. **broadcom 硬件可用性验证**：如 future 需要，可在 squashfs 内容层做
   x86_64-dellemc_s5232f_c3538-r0 platform 工件存在性校验。当前范围内明确不做
   （见 §1 目标 3：CI 只构建、不验证硬件目标）。