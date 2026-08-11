# Rockcraft + Pebble Migration: docker-sonic-mgmt-framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate docker-sonic-mgmt-framework container from Dockerfile+supervisord to Rockcraft+Pebble on the `202605_resolute_rock` branch, with both paths coexisting.

**Architecture:** A new `rockcraft.yaml` flattens the three-layer Docker inheritance chain (docker-base-resolute -> docker-config-engine-resolute -> docker-sonic-mgmt-framework) into a single Rockcraft manifest. Pebble replaces supervisord for in-container process management. `start.sh` is modified with `USE_PEBBLE` detection so both Docker and Rock paths share the same script. `build_rocks.sh` is updated to include the new container in its rocklist.

**Tech Stack:** Rockcraft, Pebble, Ubuntu Resolute (26.04), Python 3.14

## Global Constraints

- Branch: `202605_resolute_rock` (Ubuntu 26.04 / Resolute)
- Python version: 3.14 (not 3.12 like Noble)
- Build-base: `ubuntu@26.04` (not `ubuntu@24.04` like Noble)
- Rockcraft base: `base: ubuntu@26.04` (full Ubuntu base, not `base: bare`)
- Existing files must NOT be modified except `start.sh` and `build_rocks.sh`
- Both Dockerfile and Rockcraft paths must be buildable from the same branch
- Use `rockcraft.skopeo` (not `skopeo`) for OCI archive -> Docker daemon conversion
- Spec: `docs/superpowers/specs/2026-07-23-rockcraft-pebble-docker-sonic-mgmt-framework-resolute-design-en.md`
- No environment variables on pebble services (DEBIAN_FRONTEND, IMAGENAME, DISTRO are build-time only)
- No stage filter (image size not a concern)
- No supervisord packages, configs, or directories in the rock
- No timezone commands in start.sh (upstream removed these)

---

### Task 1: Create rockcraft.yaml

**Files:**
- Create: `dockers/docker-sonic-mgmt-framework/rockcraft.yaml`

**Interfaces:**
- Produces: `rockcraft.yaml` (consumed by `build_rocks.sh` in Task 3, which runs `rockcraft pack` inside this directory)
- Consumes: staged files from `build_rocks.sh` — `debs/*.deb`, `python-wheels/*.whl`, `files/*` (syslog-layer.yaml, rsyslog.conf, swss_vars.j2, readiness_probe.sh, container_startup.py), `envs`, `manifest.json`

- [ ] **Step 1: Create `dockers/docker-sonic-mgmt-framework/rockcraft.yaml`**

Write the following content:

```yaml
name: docker-sonic-mgmt-framework
summary: SONiC sonic-mgmt-framework container
description: A rock for SONiC sonic-mgmt-framework container
version: "1.0.0"

base: ubuntu@26.04
build-base: ubuntu@26.04
license: Apache-2.0

platforms:
  amd64:

services:
  rsyslogd:
    command: /usr/sbin/rsyslogd -n -iNONE
    override: replace
    startup: enabled
  start:
    command: /usr/bin/start.sh
    override: replace
    startup: enabled
    on-success: ignore
    on-failure: ignore
  rest-server:
    command: /usr/bin/rest-server.sh
    override: replace

parts:
  setup-mgmt-framework:
    plugin: dump
    source: .
    override-build: |
      craftctl default

      # Install SONiC debs
      dpkg -x debs/socat_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libswsscommon_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libyang3_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/python3-libyang_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/python3-swsscommon_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/sonic-db-cli_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/sonic-eventd_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnl-3-200_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnl-route-3-200_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnl-genl-3-200_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnl-nf-3-200_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnl-cli-3-200_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/sonic-mgmt-common_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/sonic-mgmt-framework_*.deb ${CRAFT_PART_INSTALL}

      # Clean up deb/wheel source files
      rm -rf ${CRAFT_PART_INSTALL}/debs ${CRAFT_PART_INSTALL}/python-wheels

    organize:
      start.sh: usr/bin/start.sh
      rest-server.sh: usr/bin/rest-server.sh
      mgmt_vars.j2: usr/share/sonic/templates/mgmt_vars.j2
      files/syslog-layer.yaml: usr/share/sonic/templates/syslog-layer.yaml
      files/swss_vars.j2: usr/share/sonic/templates/swss_vars.j2
      files/readiness_probe.sh: usr/bin/readiness_probe.sh
      files/container_startup.py: usr/share/sonic/scripts/container_startup.py

    stage-packages:
      - rsyslog
      - rsyslog-relp
      - python3
      - redis-tools
      - iproute2
      - net-tools
      - jq
      - libzmq5
      - libwrap0
      - libatomic1
      - libdaemon0
      - libdbus-1-3
      - libjansson4
      - python3-redis
      - python3-yaml
      - libxml2-16
      - libcurl4t64
      - libcjson1
      - libboost-serialization1.83.0
      - libhiredis1.1.0
      - libuuid1
      - libxxhash0

    override-prime: |
      craftctl default

      ln -sf /usr/bin/python3.14 usr/bin/python3

      cp ${CRAFT_PROJECT_DIR}/files/rsyslog.conf etc/rsyslog.conf
      cp ${CRAFT_PROJECT_DIR}/manifest.json manifest.json

  install-python:
    plugin: python
    source: .
    python-packages:
      - ./python-wheels/sonic_py_common-1.0-py3-none-any.whl
      - ./python-wheels/sonic_yang_mgmt-1.0-py3-none-any.whl
      - ./python-wheels/sonic_yang_models-1.0-py3-none-any.whl
      - ./python-wheels/sonic_containercfgd-1.0-py3-none-any.whl
      - ./python-wheels/sonic_config_engine-1.0-py3-none-any.whl
      - jinjanator
      - click
      - pyangbind==0.8.7
      - lxml
      - requests
      - urllib3
    stage-packages:
      - python3-venv

  add-user:
    plugin: nil
    after: [setup-mgmt-framework]

    overlay-script: |
      groupadd -R $CRAFT_OVERLAY syslog
      useradd -R $CRAFT_OVERLAY -M -r --system -g adm syslog

    prime:
      - etc/passwd
      - etc/group
```

- [ ] **Step 2: Verify file exists**

Run: `ls -la dockers/docker-sonic-mgmt-framework/rockcraft.yaml`
Expected: File exists and is non-empty.

- [ ] **Step 3: Commit**

```bash
git add dockers/docker-sonic-mgmt-framework/rockcraft.yaml
git commit -m "build: add rockcraft.yaml for docker-sonic-mgmt-framework"
```

---

### Task 2: Modify start.sh for pebble coexistence

**Files:**
- Modify: `dockers/docker-sonic-mgmt-framework/start.sh`

**Interfaces:**
- Produces: `start.sh` with pebble detection (consumed by rockcraft.yaml `start` service in Task 1 and by Dockerfile.j2's supervisord `start` program)
- Consumes: `/usr/share/sonic/templates/syslog-layer.yaml` (staged by `build_rocks.sh`)

- [ ] **Step 1: Read current start.sh**

Run: `cat dockers/docker-sonic-mgmt-framework/start.sh`

Current content:
```bash
#!/usr/bin/env bash

mkdir -p /var/sonic
echo "# Config files managed by sonic-config-engine" > /var/sonic/config_status
```

- [ ] **Step 2: Replace start.sh with pebble-aware version**

Write the following content to `dockers/docker-sonic-mgmt-framework/start.sh`:

```bash
#!/usr/bin/env bash

mkdir -p /var/sonic
echo "# Config files managed by sonic-config-engine" > /var/sonic/config_status

if pgrep -x pebble > /dev/null 2>&1; then
    LAYER_FILE="/usr/share/sonic/templates/syslog-layer.yaml"
    pebble add syslog-layer --combine $LAYER_FILE
    pebble replan
    pebble start rest-server
fi
```

- [ ] **Step 3: Verify the file**

Run: `cat dockers/docker-sonic-mgmt-framework/start.sh`
Expected: Content matches Step 2, with USE_PEBBLE detection block.

- [ ] **Step 4: Commit**

```bash
git add dockers/docker-sonic-mgmt-framework/start.sh
git commit -m "build: add pebble coexistence to start.sh for docker-sonic-mgmt-framework"
```

---

### Task 3: Add docker-sonic-mgmt-framework to build_rocks.sh

**Files:**
- Modify: `build_rocks.sh`

**Interfaces:**
- Produces: `build_rocks.sh` with the new container in the rocklist (drives `rockcraft pack` + `skopeo copy` + `docker save` for each rock)
- Consumes: `rockcraft.yaml` from Task 1, `start.sh` from Task 2, staged build artifacts in `target/{debs,files,python-wheels}/resolute/`

- [ ] **Step 1: Read current build_rocks.sh**

Run: `cat build_rocks.sh`

Current rocklist:
```bash
rocklist=(
    "dockers/docker-database"
)
```

- [ ] **Step 2: Add docker-sonic-mgmt-framework to rocklist and fix cp -r**

Edit `build_rocks.sh`:

1. Add the new entry to the rocklist array:

Old:
```bash
rocklist=(
    "dockers/docker-database"
)
```

New:
```bash
rocklist=(
    "dockers/docker-database"
    "dockers/docker-sonic-mgmt-framework"
)
```

2. Add `-r` flag to the `cp` command for files staging (needed because `target/files/resolute/` contains subdirectories like `apt/`):

Old:
```bash
    cp target/files/resolute/*               $rockitem/files/
```

New:
```bash
    cp -r target/files/resolute/*            $rockitem/files/
```

- [ ] **Step 3: Verify the change**

Run: `grep -A5 'rocklist=' build_rocks.sh && grep 'cp.*target/files' build_rocks.sh`
Expected: Both `dockers/docker-database` and `dockers/docker-sonic-mgmt-framework` in the list, and `cp -r` for files staging.

- [ ] **Step 4: Commit**

```bash
git add build_rocks.sh
git commit -m "build: add docker-sonic-mgmt-framework to build_rocks.sh rocklist"
```

---

### Task 4: Docker path regression verification

**Files:**
- No file changes. Verification only.

**Interfaces:**
- Verifies: `start.sh` changes from Task 2 do not break the Docker/supervisord path.

- [ ] **Step 1: Build the Docker image**

Run:
```bash
make SONIC_BUILD_JOBS=4 target/docker-sonic-mgmt-framework.gz
```

Expected: Build completes successfully. The `USE_PEBBLE` detection in `start.sh` does not affect the Docker path because `pgrep -x pebble` returns false in a supervisord container.

- [ ] **Step 2: If build fails, investigate**

If the build fails, check:
- `start.sh` syntax: `bash -n dockers/docker-sonic-mgmt-framework/start.sh`
- Dockerfile.j2 references to start.sh are unchanged (it COPYs start.sh to `/usr/bin/`)
- No other files were accidentally modified: `git diff --stat`

- [ ] **Step 3: Record result**

Note whether the Docker path build succeeded or failed. If it failed, document the error and fix before proceeding.

---

### Task 5: Rock build verification

**Files:**
- No file changes. Verification only.

**Interfaces:**
- Verifies: `rockcraft.yaml` from Task 1, `start.sh` from Task 2, `build_rocks.sh` changes from Task 3.

**Prerequisites:**
- Task 4 completed (Docker path build succeeded, confirming shared files are correct)
- `make` has been run (Task 4 Step 1 produces the build artifacts in `target/`)
- `build_rocks.sh` already handles both docker-database and docker-sonic-mgmt-framework

- [ ] **Step 1: Run build_rocks.sh**

Run:
```bash
./build_rocks.sh
```

Expected: Both rocks build. `target/docker-sonic-mgmt-framework.gz` is generated.

If only docker-database succeeds but docker-sonic-mgmt-framework fails, check the rockcraft build output for:
- Missing deb files (check `target/debs/resolute/` for the expected debs)
- Missing wheel files (check `target/python-wheels/resolute/` for the expected wheels)
- Missing staged files (check `target/files/resolute/` for `syslog-layer.yaml`, `rsyslog.conf`, `swss_vars.j2`, `readiness_probe.sh`, `container_startup.py`)
- Package resolution errors (add missing packages to `stage-packages`)
- Python plugin errors (check venv creation, wheel installation)

- [ ] **Step 2: Load the rock image**

Run:
```bash
docker load -i target/docker-sonic-mgmt-framework.gz
```

Expected: Image loads successfully.

- [ ] **Step 3: Run the container**

Run:
```bash
docker container stop mgmt-framework_rock 2>/dev/null || true
docker container rm mgmt-framework_rock 2>/dev/null || true
docker run -d --name mgmt-framework_rock \
  -t \
  --security-opt apparmor=unconfined \
  --security-opt="systempaths=unconfined" \
  -v /etc/sonic:/etc/sonic:ro \
  -v /etc/localtime:/etc/localtime:ro \
  -v /etc:/host_etc:ro \
  -v /var/run/dbus:/var/run/dbus:rw \
  --mount type=bind,source="/var/platform/",target="/mnt/platform/" \
  docker-sonic-mgmt-framework:latest
```

Expected: Container starts without immediate crash.

- [ ] **Step 4: Verify pebble and services are running**

Run:
```bash
docker exec mgmt-framework_rock pgrep -x pebble
docker exec mgmt-framework_rock pgrep -x rsyslogd
docker exec mgmt-framework_rock pgrep -f rest_server
```

Expected: All three commands output PIDs (non-empty).

- [ ] **Step 5: Check pebble logs for errors**

Run:
```bash
docker exec mgmt-framework_rock pebble logs
```

Expected: No ImportError, missing shared library, or crash errors in the logs.

- [ ] **Step 6: Runtime state comparison**

Compare with the existing `mgmt-framework` container (built from Dockerfile):

```bash
# Existing container
docker exec mgmt-framework ps aux
docker exec mgmt-framework dpkg -l | wc -l
docker exec mgmt-framework ls /usr/bin/start.sh /usr/bin/rest-server.sh /usr/share/sonic/templates/mgmt_vars.j2 /usr/sbin/rest_server

# New rock container
docker exec mgmt-framework_rock ps aux
docker exec mgmt-framework_rock dpkg -l | wc -l
docker exec mgmt-framework_rock ls /usr/bin/start.sh /usr/bin/rest-server.sh /usr/share/sonic/templates/mgmt_vars.j2 /usr/sbin/rest_server
```

Expected: Process lists match (rsyslogd + rest_server running). Key file locations exist in both. Package count may differ (rock uses stage-packages, Docker uses apt-get).

- [ ] **Step 7: Record results**

Document:
- Whether the rock built successfully
- Whether all three services (pebble, rsyslogd, rest-server) are running
- Whether pebble logs show any errors
- Runtime state comparison results
- Any missing packages or files discovered during testing (add to spec's known issues)

If issues are found, iterate:
- Missing shared library -> add the package to `stage-packages` in `dockers/docker-sonic-mgmt-framework/rockcraft.yaml`
- Missing Python module -> add to `python-packages` in the `install-python` part
- Missing file -> check if it should be staged by `build_rocks.sh` or added to `organize`
- Commit fixes and re-run from Step 1
