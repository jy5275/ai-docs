# Resolute SONiC CI 流水线实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 canonical/sonic-buildimage 的 `202605_resolute` 分支落地一套不依赖 testflinger 的 CI，在 `[self-hosted, resolute, amd64, large]` runner 上以 merge queue 门禁方式构建 vs 与 broadcom 两个 platform target。

**Architecture:** 单个 workflow（`resolute-build.yml`）+ 一个本地 composite action（复用前置安装）。两个 job：`build-vs` / `build-broadcom`，互不依赖、并发执行，各自构建目标 platform 的全部包（默认跑内嵌单测）并直构 target。触发源为 `merge_group`（checks_requested）、`workflow_dispatch`（手动）与 `push: ci-workflow/*`（干跑通道，本计划新增，见 Task 1「设计偏差」）。

**Tech Stack:** GitHub Actions（self-hosted runner）、SONiC buildimage 构建体系（make / sonic-slave docker 容器）、docker-ce（含 buildx plugin）、jinjanator、gh CLI、actionlint。

**设计文档:** `~/repos/ai-docs/sonic-buildimage/2026-09-04-resolute-build-ci-design.md`（已批准，权威依据）

## Global Constraints

- 触发：`merge_group` 仅对 `202605_resolute`；PR 的 open/sync 不触发；不做构建缓存跨 job 复用。
- runner：`runs-on: [self-hosted, resolute, amd64, large]`（8 CPU / 32 GiB / 100 GiB，临时 VM，每次重置，passwordless sudo，Ubuntu Resolute 系统）。
- 环境参数（所有 make 步骤都生效）：`SONIC_BUILD_JOBS=4`、`SONIC_BUILD_RETRY_COUNT=3`、`SONIC_BUILD_MEMORY=24g`（经 `rules/config.user`）。
- 构建镜像源用默认源，不设 MIRROR_URLS。
- 两个 build job 均不设置 `BUILD_SKIP_TEST`（默认跑内嵌单测），且无 `needs` 依赖、并发执行。
- 不构建任何 dbg 镜像；broadcom 产物不做装机/运行验证。
- job `timeout-minutes: 720`；artifact 保留 7 天；失败时打包上传构建日志。
- 系统必须安装 `docker-buildx-plugin`（或无 buildx 时用 Ubuntu 仓库的 `docker.io` + `docker-buildx`）——实测 docker-ce 29 缺 buildx 会退回 legacy builder、无 GC、磁盘暴涨。
- 提交前缀用 `build:`（本仓 AGENTS 约束）；改动只落在 sonic-buildimage 工作区/分支，不提交设计文档（文档在 ai-docs 仓库）。

## 文件结构

- Create: `.github/workflows/resolute-build.yml` —— 唯一 CI workflow：两个 job、触发、artifact、日志收集。
- Create: `.github/actions/resolute-build-setup/action.yml` —— composite action：docker/jinjanator 安装（幂等）、`rules/config.user` 写入、环境信息水位输出。被两个 job 复用，避免两份重复 shell。
- Create: `.github/actions/resolute-build-setup/install-prerequisites.sh` —— 前置安装 shell 脚本（幂等安装 docker-ce/buildx、jinjanator 等），从 action.yml 以 `bash ${{ github.action_path }}/install-prerequisites.sh` 引用，使长 shell 独立成文件、便于语法高亮与排错。
- Create: `.github/actionlint.yaml` —— actionlint 配置，登记 self-hosted runner 自定义 label（`self-hosted`/`resolute`/`amd64`/`large`），否则 Task 1 Step 4 的裸跑校验会报 `[runner-label]` 误报（actionlint 官方建议做法）。
- 无其他文件改动。仓库设置变更（branch protection / merge queue）见 Task 6，通过 gh API 或 UI 完成，不落文件。

---

### Task 1: 创建 workflow 与 composite action 文件并静态校验

**Files:**
- Create: `.github/workflows/resolute-build.yml`
- Create: `.github/actions/resolute-build-setup/action.yml`
- Create: `.github/actions/resolute-build-setup/install-prerequisites.sh`
- Create: `.github/actionlint.yaml`

**Interfaces:**
- Consumes: 无。
- Produces:
  - workflow 名 `resolute-build`；job 名 `build-vs` / `build-broadcom`（这两个名字即日后 branch protection 的 required check context，不可再改）。
  - composite action 以 `uses: ./.github/actions/resolute-build-setup` 引用，无输入输出参数。

**设计偏差声明（需用户知悉）**：spec 的触发源只有 merge_group + workflow_dispatch。本计划额外保留 `push: ci-workflow/*` 触发（沿用 noble 时代 run_testbed.yml 的 `test/*` 惯例），作为「workflow 尚未合入时也能在 canonical 真机干跑」的通道。合入后保留它不影响 merge queue 行为。

- [ ] **Step 1: 建实现分支**

```bash
cd /home/ubuntu/repos/sonic-buildimage
git checkout 202605_resolute
git pull --ff-only origin 202605_resolute
git checkout -b ci/resolute-basic-build
git status
```

Expected: 干净工作区，新分支 `ci/resolute-basic-build`。

- [ ] **Step 2: 创建 workflow 文件**

写入 `.github/workflows/resolute-build.yml`，内容如下（完整、无占位）：

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
        type: string
        default: 202605_resolute
  push:
    branches: [ci-workflow/*]

concurrency:
  group: resolute-build-${{ github.ref }}
  cancel-in-progress: true

env:
  SONIC_BUILD_JOBS: "4"
  SONIC_BUILD_RETRY_COUNT: "3"

jobs:
  build-vs:
    runs-on: [self-hosted, resolute, amd64, large]
    timeout-minutes: 720
    steps:
      - name: Checkout merge/pr ref
        uses: actions/checkout@v4
        with:
          ref: ${{ github.event.inputs.ref || github.ref }}
          fetch-depth: 0
          submodules: recursive
      - name: Setup build prerequisites
        uses: ./.github/actions/resolute-build-setup
      - name: Build sonic-vs image
        run: |
          make init
          make configure PLATFORM=vs
          make target/sonic-vs.img.gz
      - name: Upload sonic-vs image
        uses: actions/upload-artifact@v4
        with:
          name: sonic-vs-img
          path: target/sonic-vs.img.gz
          retention-days: 7
          if-no-files-found: error
      - name: Collect logs on failure
        if: failure()
        run: |
          find target -name '*.log' -type f -print0 | tar --null -czf build-vs-logs.tgz --files-from=- 2>/dev/null || touch build-vs-logs.tgz
          ls -la build-vs-logs.tgz
      - name: Upload logs on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: build-vs-failure-logs
          path: build-vs-logs.tgz
          retention-days: 7
          if-no-files-found: ignore

  build-broadcom:
    runs-on: [self-hosted, resolute, amd64, large]
    timeout-minutes: 720
    steps:
      - name: Checkout merge/pr ref
        uses: actions/checkout@v4
        with:
          ref: ${{ github.event.inputs.ref || github.ref }}
          fetch-depth: 0
          submodules: recursive
      - name: Setup build prerequisites
        uses: ./.github/actions/resolute-build-setup
      - name: Build sonic-broadcom image
        run: |
          make init
          make configure PLATFORM=broadcom
          make target/sonic-broadcom.bin
      - name: Upload sonic-broadcom image
        uses: actions/upload-artifact@v4
        with:
          name: sonic-broadcom-bin
          path: target/sonic-broadcom.bin
          retention-days: 7
          if-no-files-found: error
      - name: Collect logs on failure
        if: failure()
        run: |
          find target -name '*.log' -type f -print0 | tar --null -czf build-brcm-logs.tgz --files-from=- 2>/dev/null || touch build-brcm-logs.tgz
          ls -la build-brcm-logs.tgz
      - name: Upload logs on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: build-broadcom-failure-logs
          path: build-brcm-logs.tgz
          retention-days: 7
          if-no-files-found: ignore
```

注意点（已内置在文件里）：
- `github.event.inputs.ref || github.ref`：push/merge_group 事件无 inputs，回落其自身 ref。
- 两个 build job 不设 `BUILD_SKIP_TEST`：保持默认（`rules/config:404` 为 `?= n`），包构建时内嵌单测照常运行。

- [ ] **Step 3: 创建 composite action**

写入 `.github/actions/resolute-build-setup/action.yml`：

```yaml
name: resolute-build-setup
description: |
  Idempotently install SONiC build prerequisites (docker-ce/buildx, jinjanator),
  write rules/config.user, and print environment watermarks.
  Runner assumptions: Ubuntu Resolute, passwordless sudo.
runs:
  using: composite
  steps:
    - name: Install prerequisites
      shell: bash
      run: bash ${{ github.action_path }}/install-prerequisites.sh
    - name: Write build config
      shell: bash
      run: |
        printf 'SONIC_BUILD_MEMORY = 24g\n' > rules/config.user
        cat rules/config.user
    - name: Disk watermark
      shell: bash
      run: |
        df -h /
        docker system df || true
```

`install-prerequisites.sh`（与 action.yml 同目录，execute 位无硬要求，经 `bash` 显式调用）：

```bash
#!/usr/bin/env bash
set -eux
sudo modprobe overlay
install_docker_ce() {
  sudo apt-get update -qq
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
}
if ! command -v docker >/dev/null 2>&1; then
  set +e
  install_docker_ce
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "docker-ce official repo failed, falling back to Ubuntu archive docker.io"
    sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg
    sudo apt-get update -qq
    sudo apt-get install -y docker.io docker-buildx
  fi
elif ! docker buildx version >/dev/null 2>&1; then
  echo 'docker present but buildx plugin missing; installing'
  set +e
  sudo apt-get update -qq
  sudo apt-get install -y docker-buildx
  rc=$?
  set -e
  if [ $rc -ne 0 ] || ! docker buildx version >/dev/null 2>&1; then
    echo 'Ubuntu docker-buildx unavailable; trying docker.com repo'
    set +e
    install_docker_ce
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then
      echo 'WARN: docker-buildx-plugin install failed'
      sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg
      sudo apt-get update -qq || true
    fi
  fi
fi
sudo apt-get install -y make git jq python3-pip
pip3 install --user --quiet jinjanator || pip3 install --user --quiet --break-system-packages jinjanator
echo "$HOME/.local/bin" >> "$GITHUB_PATH"
sudo gpasswd -a "$(id -un)" docker || true
sudo systemctl restart docker
sudo chmod a+rw /var/run/docker.sock
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
docker buildx version || echo 'WARN: buildx plugin missing'
j2 --version 2>/dev/null || jinjanate --version 2>/dev/null || echo 'WARN: j2/jinjanate missing'
docker ps >/dev/null && echo 'docker socket OK'
```

说明：docker-ce 安装失败（如 26.04 codename 尚无官方仓支持）自动回退 Ubuntu 仓库 `docker.io` + `docker-buildx`；pip 装 jinjanator 失败时自动加 `--break-system-packages`（PEP 668 环境）；`chmod a+rw /var/run/docker.sock` 回避新 group 需要重登录的问题（noble 时代 CI 同做法）。`modprobe overlay` 不吞失败：SONiC 构建的嵌套 dockerd 依赖 overlay 文件系统（README 的前置之一），失败必须快速阻断而非带病硬跑；overlay 为内核内建时 modprobe 返回 0，不受影响。

修订说明（源自 Task 2 第一次干跑）：
- **buildx 补装分支（新增）**：runner 预装 docker 而无 buildx plugin（干跑实测 `unknown command: docker buildx`）。docker 存在但没有 buildx 时，先试 Ubuntu 仓库 `docker-buildx`（不引入 docker-ce 依赖），失败再加 docker.com 仓装 `docker-buildx-plugin`；两路都失败只 WARN 并清理本分支落盘的 docker.list/docker.gpg（复审补：与 docker 不存在分支的失败清理保持对称），不硬阻断（后续 job 若因无 buildx 退 legacy builder 会由磁盘水位暴露）。
- （已撤销）曾一并提交 apt 源去重与日志输出过滤方案，用户 2026-09-05 判定 over-engineering 后全部撤销，仅登记在设计文档 §7 迭代项。

- [ ] **Step 4: 安装并运行 actionlint 静态校验**

```bash
cat > .github/actionlint.yaml <<'EOF'
self-hosted-runner:
  labels:
    - self-hosted
    - resolute
    - amd64
    - large
EOF
LATEST=$(curl -fsSL https://api.github.com/repos/rhysd/actionlint/releases/latest | jq -r .tag_name)
mkdir -p /tmp/opencode/actionlint && cd /tmp/opencode/actionlint
curl -fsSL -o actionlint.tar.gz "https://github.com/rhysd/actionlint/releases/download/${LATEST}/actionlint_${LATEST#v}_linux_amd64.tar.gz"
tar xzf actionlint.tar.gz
cd /home/ubuntu/repos/sonic-buildimage
/tmp/opencode/actionlint/actionlint .github/workflows/resolute-build.yml
```

Expected: 无输出、exit 0。若有输出，按行修正后重跑至通过。

- [ ] **Step 5: 提交**

```bash
git add .github/workflows/resolute-build.yml .github/actions/resolute-build-setup/action.yml .github/actions/resolute-build-setup/install-prerequisites.sh .github/actionlint.yaml
git commit -m "build(ci): add resolute merge-queue build workflow for vs and broadcom"
git log --oneline -1
```

Expected: 单 commit，仅含上述四个文件。

---

### Task 2: 推到 canonical 的干跑分支并观察全链路

**Files:** 无新文件（沿用 Task 1 产物）。

**Interfaces:**
- Consumes: Task 1 的 workflow + composite action。
- Produces: 绿化的 workflow（可进 PR 状态）、踩坑清单（供文档）。

> **重跑注记（2026-09-04 run 1 后修订）**：本 Task 已执行过一轮（run 33855288953，
> 分支 `ci-workflow/resolute-dryrun`）。发现两处配置问题（buildx 缺失、日志噪音），
> Task 1 产物已 amend 修订。本轮重跑改用新分支 `ci-workflow/resolute-dryrun2`
> （原分支保持不动，避免对 canonical force-push；多个干跑分支最终都在 Task 3/6
> 清理）。run 1 还发现 test-vs（当时的 job 结构）在 p4lang-pi 包上失败，系代码/上游
> 问题，属 Step 4 分类的「包构建失败」类——workflow 本身工作正常，不产生额外
> workflow 修正。注意：r1-r3 均在「test-vs + 双 build」结构下；2026-09-05 起结构
> 改为仅双 build job 并发（见 Task 1「设计偏差·结构修订」），后续干跑按新结构观察。

- [ ] **Step 1: 推到 canonical 的 ci-workflow 分支触发 push 触发（重跑）**

```bash
git push origin ci/resolute-basic-build:ci-workflow/resolute-dryrun2
```

Expected: push 成功；`gh run list -b ci-workflow/resolute-dryrun2 --workflow resolute-build.yml` 出现新 run（约 1-2 分钟后稳定）。

- [ ] **Step 2: 观察 run 启动**

```bash
gh run list -b ci-workflow/resolute-dryrun2 --workflow resolute-build.yml -L 5
gh run watch $(gh run list -b ci-workflow/resolute-dryrun2 --workflow resolute-build.yml -L 1 --json databaseId -q '.[0].databaseId') --exit-status --interval 60
```

Expected: run 进入 in_progress 且被 `[self-hosted, resolute, amd64, large]` runner 拾取（若长时间 queued：检查 runner 是否在线、label 拼写）。

- [ ] **Step 3: 检查 setup 阶段输出与降噪效果**

```bash
gh run view <run-id> --log --job $(gh run view <run-id> --json jobs -q '.jobs[0].databaseId') | grep -E 'docker socket OK|buildx version|client=|server=|WARN'
```

Expected：`docker socket OK`；`client=29.x server=29.x`；**`docker buildx version` 有版本号、无 `WARN: buildx plugin missing`**（run 1 实测缺失，已在 Task 1 Step 3 修复）。若发现 buildx 缺失 → docker 安装分支走错，回 Task 1 Step 3 修正安装逻辑并 amend。

- [ ] **Step 4: 记录常见失败场景的处理（不修改构建体系本身）**

按日志分类排查：
- `make list` 无 deb 行 → `make configure` 未成功或 PLATFORM 值错误，查 configure 步骤日志。
- 包构建失败且 target/debs/*.log 存在 → 下载 failure-logs artifact，是代码问题（与 upstream 对比）而非 CI 配置问题——此时 workflow 工作正常，任务达成的判定以「job 结构按预期运行、日志可收集、artifact 可下载」为准。
- `No space left on device` → `df` 水位步骤输出对比 §5 预算表；缓解顺序：检查 dbg 未构建、必要时降 `SONIC_BUILD_JOBS=3`。

Expected: 两个 job 完成（绿或红绿皆可接受，只要结构正确）；若全绿：vs 与 broadcom artifact 均存在。

- [ ] **Step 5: 验证 artifact 可下载**

若 build job 绿色：

```bash
gh run view <run-id> --log --json artifacts -q '.artifacts[] | [.name, .sizeInBytes]'
gh run download <run-id> -n sonic-vs-img -D /tmp/opencode/artifacts
ls -la /tmp/opencode/artifacts/
rm -rf /tmp/opencode/artifacts
```

Expected: 大小量级与设计一致（vs 约 2-3G、broadcom 约 2-3G），下载解包成功。红色则跳过，记录原因。

- [ ] **Step 6: 执行结果记录（三次干跑已发生，2026-09-05 补记）**

实测三轮：r1 33855288953（dryrun，发现 buildx 缺失 + 日志噪音）→ 修订；r2 33884212829（dryrun2，buildx 补装验证通过：buildx 0.30.1 无 WARN、docker socket OK；当时结构的 test-vs 于 p4lang-pi 失败）→ 用户指令尝试修复 test 失败；r3 33965218171（dryrun3，p4lang-pi 修复验证生效，随后 p4lang-bmv2 暴露未用依赖）。CI 配置验收在 r2 已达成；后续包级失败按 Step 4 分类属代码问题。

**拆分决定（用户 2026-09-05）**：包修复不进 CI 交付。CI 只含 workflow 相关三文件（commit c06ea4014）；p4lang-pi（`fix-gtest-cstdint.patch`）与 p4lang-bmv2（去掉未用 python3-six）两个修复落独立分支 `fix/resolute-gcc15-test-backlog`（两个 `fix(resolute):` commit，从 2d608feb6 起），另行推进验证与 PR。CI 分支的两个 build job（默认跑单测）在 202605_resolute 上会保持红色直至包修复 backlog 合入——这是预期状态，不阻塞本计划前四个 Task。

---

### Task 3: 干跑分支清理与 PR

**Files:** 无。

**Interfaces:**
- Consumes: Task 2 的验证结论。
- Produces: 合入 202605_resolute 的 workflow。

- [ ] **Step 1: 删除干跑分支；把 PR 分支指向 202605_resolute**

```bash
git push origin --delete ci-workflow/resolute-dryrun ci-workflow/resolute-dryrun2 ci-workflow/resolute-dryrun3
```

Expected: 远端干跑分支全部删除。

- [ ] **Step 2: 开 PR**

```bash
git push origin ci/resolute-basic-build
gh pr create --repo canonical/sonic-buildimage \
  --base 202605_resolute --head ci/resolute-basic-build \
  --title "build(ci): resolute merge-queue build workflow (vs + broadcom)" \
  --body "Adds .github/workflows/resolute-build.yml and a local composite action,
per the design doc (resolute build CI without Testflinger).
Triggers: merge_group (checks_requested) + workflow_dispatch + push ci-workflow/*.
Dry runs (already deleted branches): ci-workflow/resolute-dryrun (run 33855288953,
found runner without buildx, fixed and re-verified), ci-workflow/resolute-dryrun2
(run 33884212829, buildx fix verified), ci-workflow/resolute-dryrun3 (run 33965218171,
carried an unrelated p4lang fix experiment).
CI does not run on PR open/sync; verified after merge via merge queue or dispatch.
Known state: with embedded tests enabled, the build jobs fail on 202605_resolute
(package-level GCC15/migration backlog, tracked separately); merge queue gating is
deliberately deferred until both jobs go green (see plan Task 5 precondition)."
```

Expected: PR URL 输出。注意：PR 本身不会触发本 workflow（设计如此），reviewers 需知悉。

- [ ] **Step 3: 等评审合并（人肉步骤，由用户执行或触发）**

Expected: PR 合并到 202605_resolute。

---

### Task 4: 在 202605_resolute 上 dispatch 手动验证（可选，若 Task 2 未全绿则必做）

**Files:** 无。

**Interfaces:**
- Consumes: 已合入 202605_resolute 的 workflow。

- [ ] **Step 1: 经 API 对 202605_resolute 触发 dispatch**

```bash
gh api --method POST \
  repos/canonical/sonic-buildimage/actions/workflows/resolute-build.yml/dispatches \
  -f ref=202605_resolute
```

Expected: HTTP 204。

- [ ] **Step 2: 观察至完成**

```bash
gh run list --workflow resolute-build.yml -L 3
gh run watch <run-id> --exit-status --interval 60
```

Expected: 两 job 绿，artifacts 两个 image 可下载。

---

### Task 5: 启用 merge queue 与 required checks

**Files:** 无（仓库设置）。

**Interfaces:**
- Consumes: Task 3 的合并结果（以及两个 build job 在 202605_resolute 上转绿——见前置条件）。
- Produces: 门禁生效的 merge queue；job 名 `build-vs`/`build-broadcom` 为 required check context。

> **前置条件（2026-09-05 修订，拆分决定的直接推论）**：merge queue（ALLGREEN + required checks 指向两 job）一旦开启，任何进入 202605_resolute 的 PR 都必须等 build-vs/build-broadcom 双绿。当前两个 build job 在该分支为红（包修复 backlog 在 `fix/resolute-gcc15-test-backlog` 独立推进），**因此 Task 5 必须等两 job 在 202605_resolute 的 merge queue 上转绿后（即包修复 PR 合入并验证绿）再执行**。在那之前不得修改 branch protection / 创建 ruleset。Task 4 的 dispatch 验证可先做（预期红属正常，记录即可）。

- [ ] **Step 1: 记录现状**

```bash
gh api repos/canonical/sonic-buildimage/branches/202605_resolute/protection | jq '{required_status_checks, merge_queue: .required_merge_queue}'
```

Expected: 输出当前保护设置（若 404 说明分支无保护，属正常，继续）。

- [ ] **Step 2: 配置 required checks（保留既有设置合并 context）**

先手工把 Step 1 输出中的 `required_status_checks.contexts` 与新 context 集合并集后写入 `/tmp/opencode/protection.json`：

```json
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["build-vs", "build-broadcom"]
  },
  "enforce_admins": null,
  "required_pull_request_reviews": null,
  "restrictions": null
}
```

（若 Step 1 显示已有 reviews/restrictions 等设置，必须原样保留，不得置 null 覆盖。）

```bash
gh api --method PUT \
  repos/canonical/sonic-buildimage/branches/202605_resolute/protection \
  --input /tmp/opencode/protection.json | jq '.required_status_checks'
```

Expected: 返回的 contexts 含两个 job 名。

- [ ] **Step 3: 创建 merge queue ruleset**

```bash
cat > /tmp/opencode/ruleset.json <<'EOF'
{
  "name": "resolute merge queue",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/202605_resolute"], "exclude": [] } },
  "rules": [
    {
      "type": "merge_queue",
      "parameters": {
        "grouping_strategy": "ALLGREEN",
        "check_response_timeout_minutes": 1440,
        "merge_method": "MERGE"
      }
    }
  ],
  "bypass_actors": []
}
EOF
gh api --method POST repos/canonical/sonic-buildimage/rulesets --input /tmp/opencode/ruleset.json
```

Expected: 201 返回 ruleset 详情。若 422（参数不支持或规则冲突），转 Step 4 UI 方式。

- [ ] **Step 4: UI 兜底（仅当 Step 3 失败）**

浏览器打开 `https://github.com/canonical/sonic-buildimage/settings/rules` → New branch ruleset → Branch target → add target `202605_resolute` → Rules: 勾选 **Require merge queue**（全绿分组、超时 1440 分钟、merge commit）→ 保存。随后 `Settings → Branches` 打开 merge queue 开关确保 active。

- [ ] **Step 5: 确认终态**

```bash
gh api repos/canonical/sonic-buildimage/branches/202605_resolute/protection --jq '.required_status_checks.contexts'
gh api repos/canonical/sonic-buildimage/rulesets --jq '.[] | select(.name=="resolute merge queue") | .name'
```

Expected: contexts 整齐、ruleset 存在。

---

### Task 6: 端到端验收（测试 PR → 入队 → 自动合并 → 清理）

> **依赖 Task 5 前置条件**：本 Task 同样只能在两个 build job 于 202605_resolute 转绿后执行，否则探针 PR 无法通过门禁。落地顺序：CI PR 合入 → 包修复 PR（fix/resolute-gcc15-test-backlog）合入并验证绿 → Task 5 → Task 6。

**Files:**
- Create: `docs/merge-queue-probe.md`（验收探针文件，验收完成后删除）
- Modify: 无

**Interfaces:**
- Consumes: Task 5 的 merge queue。
- Produces: 端到端绿证据；验收完成后该探针文件被移除。

- [ ] **Step 1: 创建探针 PR**

```bash
git checkout 202605_resolute && git pull --ff-only origin 202605_resolute
git checkout -b ci/e2e-mergequeue-probe
printf '# merge queue probe\n\n接受自动合并后本文件将被删除。\n' > docs/merge-queue-probe.md
git add docs/merge-queue-probe.md
git commit -m "build(ci): add merge queue e2e probe file"
git push origin ci/e2e-mergequeue-probe
gh pr create --repo canonical/sonic-buildimage --base 202605_resolute --head ci/e2e-mergequeue-probe \
  --title "build(ci): merge queue e2e probe" \
  --body "探针 PR：验证 merge queue 全流程。合入后用另一个 PR 删除探针文件。"
```

Expected: PR 打开。观察该 PR 不应触发任何 `resolute-build` run（未入队）。

- [ ] **Step 2: 入队并观察**

```bash
gh pr ready --repo canonical/sonic-buildimage <pr-number> --undo   # 仅当草稿
# 入队（需要该 PR 已满足评审要求；探针 PR 可能需先获得 required review）
gh api --method POST repos/canonical/sonic-buildimage/pulls/<pr-number>/merge \
  -f merge_method=merge -f auto_merge=false 2>/dev/null || true
```

（若无评审豁免，让用户点「Add to merge queue」按钮。）

```bash
gh run list --workflow resolute-build.yml -L 3
```

Expected: 出现 `merge_group` 触发的 run，ref 形如 `gh-readonly-queue/202605_resolute/pr-<n>-...`。watch 至两 job 绿：

```bash
gh run watch <run-id> --exit-status --interval 60
```

- [ ] **Step 3: 确认自动合并与产物**

```bash
gh pr view <pr-number> --repo canonical/sonic-buildimage --json state,mergedAt -q '"state=" + .state + " mergedAt=" + (.mergedAt|tostring)'
gh run view <run-id> --json artifacts -q '.artifacts[].name'
```

Expected: state=MERGED、artifacts 含 sonic-vs-img 与 sonic-broadcom-bin。

- [ ] **Step 4: 清理探针（同样走 merge queue）**

```bash
git checkout ci/resolute-basic-build 2>/dev/null || git checkout -b ci/e2e-mergequeue-cleanup origin/202605_resolute
git checkout -B ci/e2e-mergequeue-cleanup origin/202605_resolute
git rm docs/merge-queue-probe.md
git commit -m "build(ci): remove merge queue e2e probe file"
git push origin ci/e2e-mergequeue-cleanup
gh pr create --repo canonical/sonic-buildimage --base 202605_resolute --head ci/e2e-mergequeue-cleanup \
  --title "build(ci): remove merge queue probe" --body "清理验收探针文件。"
```

Expected: 如 Step 2/3 流程，再次走通 merge queue 后关闭验收。

- [ ] **Step 5: 收尾**

```bash
git push origin --delete ci/e2e-mergequeue-probe ci/e2e-mergequeue-cleanup 2>/dev/null || true
git push origin --delete ci-workflow/resolute-dryrun ci-workflow/resolute-dryrun2 ci-workflow/resolute-dryrun3 2>/dev/null || true
git branch -d ci/resolute-basic-build ci/e2e-mergequeue-probe ci/e2e-mergequeue-cleanup 2>/dev/null || true
```

Expected: 远端干跑/探针分支清理完成，本地仅剩 202605_resolute。

---

## Self-Review 结论（写计划时已核对）

1. **Spec 覆盖**：§1 目标（两 target 构建）→ Task 2/4 验证；§2 全部决策落为 Global Constraints；§3 结构 → Task 1 文件；§4 job 细节（SETUP/test/build/artifact/logs）→ Task 1/2；§6 验证与上线 → Task 2/4/5/6；§7 迭代项不在本计划范围（仅缓存/group 留待后续）。
2. **占位符**：所有 shell/GH 命令、YAML 均为完整内容。
3. **一致性**：job 名两处一致（workflow、protection contexts）；`BUILD_SKIP_TEST` 不设值（默认跑单测）与设计一致；`timeout-minutes: 720`、artifact 7 天与约束一致。
4. **修订追踪**：2026-09-04 run 33855288953 后增加 buildx 补装分支（保留）；日志降噪方案（apt 源去重 + tee/过滤 + Collect 并入）曾实现，用户 2026-09-05 判定 over-engineering 后**全部撤销**，仅登记设计文档 §7 迭代项。Task 2 改用新干跑分支重跑（避免 force），Step 3 期望随修订更新；Task 3/6 清理命令覆盖所有干跑分支。设计依据见设计文档 §6.2。