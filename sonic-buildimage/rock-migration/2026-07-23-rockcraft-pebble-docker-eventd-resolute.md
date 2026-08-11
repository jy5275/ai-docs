# Rockcraft + Pebble Migration: docker-eventd Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate docker-eventd container from Dockerfile+supervisord to Rockcraft+Pebble on the `202605_resolute_rock` branch, with both paths coexisting.

**Architecture:** A new `rockcraft.yaml` flattens the three-layer Docker inheritance chain (docker-base-resolute -> docker-config-engine-resolute -> docker-eventd) into a single Rockcraft manifest. Pebble replaces supervisord for in-container process management. `start.sh` is modified with pebble detection so both Docker and Rock paths share the same script. `build_rocks.sh` is updated to include the new container in its rocklist.

**Tech Stack:** Rockcraft, Pebble, Ubuntu Resolute (26.04), Python 3.14

## Global Constraints

- Branch: `202605_resolute_rock` (Ubuntu 26.04 / Resolute)
- Python version: 3.14
- Build-base: `ubuntu@26.04`
- Rockcraft base: `base: ubuntu@26.04` (full Ubuntu base, not `base: bare`)
- Existing files must NOT be modified except `start.sh` and `build_rocks.sh`
- Both Dockerfile and Rockcraft paths must be buildable from the same branch
- Use `rockcraft.skopeo` (not `skopeo`) for OCI archive -> Docker daemon conversion
- No environment variables on pebble services
- No stage filter (image size not a concern)
- No supervisord packages, configs, or directories in the rock
- No timezone commands in start.sh
- deb filenames use wildcards (`*_*.deb`)

---

### Task 1: Create rockcraft.yaml

**Files:**
- Create: `dockers/docker-eventd/rockcraft.yaml`

**Interfaces:**
- Produces: `rockcraft.yaml` (consumed by `build_rocks.sh` in Task 3)
- Consumes: staged files from `build_rocks.sh` — `debs/*.deb`, `python-wheels/*.whl`, `files/*` (syslog-layer.yaml, rsyslog.conf, swss_vars.j2, readiness_probe.sh, container_startup.py, rsyslog_plugin.conf.j2), `manifest.json`

- [ ] **Step 1: Create `dockers/docker-eventd/rockcraft.yaml`**

Write the following content:

```yaml
name: docker-eventd
summary: SONiC eventd container
description: A rock for SONiC eventd container
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
  eventd:
    command: /usr/bin/eventd
    override: replace
  eventdb:
    command: /usr/bin/eventdb_wrapper.sh
    override: replace
    on-success: ignore
    on-failure: ignore

parts:
  setup-eventd:
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

      # Render rsyslog plugin conf files from j2 templates
      mkdir -p ${CRAFT_PART_INSTALL}/etc/rsyslog.d/rsyslog_plugin_conf
      j2 -f json ${CRAFT_PART_INSTALL}/files/rsyslog_plugin.conf.j2 ${CRAFT_PART_INSTALL}/host_events_info.json > ${CRAFT_PART_INSTALL}/etc/rsyslog.d/rsyslog_plugin_conf/host_events.conf
      j2 -f json ${CRAFT_PART_INSTALL}/files/rsyslog_plugin.conf.j2 ${CRAFT_PART_INSTALL}/bgp_events_info.json > ${CRAFT_PART_INSTALL}/etc/rsyslog.d/rsyslog_plugin_conf/bgp_events.conf
      j2 -f json ${CRAFT_PART_INSTALL}/files/rsyslog_plugin.conf.j2 ${CRAFT_PART_INSTALL}/dhcp_relay_events_info.json > ${CRAFT_PART_INSTALL}/etc/rsyslog.d/rsyslog_plugin_conf/dhcp_relay_events.conf
      j2 -f json ${CRAFT_PART_INSTALL}/files/rsyslog_plugin.conf.j2 ${CRAFT_PART_INSTALL}/swss_events_info.json > ${CRAFT_PART_INSTALL}/etc/rsyslog.d/rsyslog_plugin_conf/swss_events.conf
      j2 -f json ${CRAFT_PART_INSTALL}/files/rsyslog_plugin.conf.j2 ${CRAFT_PART_INSTALL}/syncd_events_info.json > ${CRAFT_PART_INSTALL}/etc/rsyslog.d/rsyslog_plugin_conf/syncd_events.conf

      # Remove j2 template and json source files
      rm -f ${CRAFT_PART_INSTALL}/files/rsyslog_plugin.conf.j2
      rm -f ${CRAFT_PART_INSTALL}/host_events_info.json
      rm -f ${CRAFT_PART_INSTALL}/bgp_events_info.json
      rm -f ${CRAFT_PART_INSTALL}/dhcp_relay_events_info.json
      rm -f ${CRAFT_PART_INSTALL}/swss_events_info.json
      rm -f ${CRAFT_PART_INSTALL}/syncd_events_info.json

      # Clean up deb/wheel source files
      rm -rf ${CRAFT_PART_INSTALL}/debs ${CRAFT_PART_INSTALL}/python-wheels

    organize:
      start.sh: usr/bin/start.sh
      eventdb_wrapper.sh: usr/bin/eventdb_wrapper.sh
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
    stage-packages:
      - python3-venv

  add-user:
    plugin: nil
    after: [setup-eventd]

    overlay-script: |
      groupadd -R $CRAFT_OVERLAY syslog
      useradd -R $CRAFT_OVERLAY -M -r --system -g adm syslog

    prime:
      - etc/passwd
      - etc/group
```

- [ ] **Step 2: Verify file exists**

Run: `ls -la dockers/docker-eventd/rockcraft.yaml`
Expected: File exists and is non-empty.

- [ ] **Step 3: Commit**

```bash
git add dockers/docker-eventd/rockcraft.yaml
git commit -m "build: add rockcraft.yaml for docker-eventd"
```

---

### Task 2: Modify start.sh for pebble coexistence

**Files:**
- Modify: `dockers/docker-eventd/start.sh`

**Interfaces:**
- Produces: `start.sh` with pebble detection (consumed by rockcraft.yaml `start` service and by Dockerfile.j2's supervisord `start` program)
- Consumes: `/usr/share/sonic/templates/syslog-layer.yaml` (staged by `build_rocks.sh`)

- [ ] **Step 1: Read current start.sh**

Run: `cat dockers/docker-eventd/start.sh`

Current content:
```bash
#!/usr/bin/env bash

if [ "${RUNTIME_OWNER}" == "" ]; then
    RUNTIME_OWNER="kube"
fi
```

- [ ] **Step 2: Replace start.sh with pebble-aware version**

Write the following content to `dockers/docker-eventd/start.sh`:

```bash
#!/usr/bin/env bash

if [ "${RUNTIME_OWNER}" == "" ]; then
    RUNTIME_OWNER="kube"
fi

if pgrep -x pebble > /dev/null 2>&1; then
    LAYER_FILE="/usr/share/sonic/templates/syslog-layer.yaml"
    pebble add syslog-layer --combine $LAYER_FILE
    pebble replan
    pebble start eventd
    pebble start eventdb
fi
```

- [ ] **Step 3: Verify the file**

Run: `cat dockers/docker-eventd/start.sh`
Expected: Content matches Step 2, with pebble detection block.

- [ ] **Step 4: Commit**

```bash
git add dockers/docker-eventd/start.sh
git commit -m "build: add pebble coexistence to start.sh for docker-eventd"
```

---

### Task 3: Add docker-eventd to build_rocks.sh

**Files:**
- Modify: `build_rocks.sh`

**Interfaces:**
- Produces: `build_rocks.sh` with the new container in the rocklist
- Consumes: `rockcraft.yaml` from Task 1, `start.sh` from Task 2, staged build artifacts in `target/{debs,files,python-wheels}/resolute/`

- [ ] **Step 1: Read current build_rocks.sh**

Run: `cat build_rocks.sh`

- [ ] **Step 2: Add docker-eventd to rocklist**

Edit `build_rocks.sh`:

Old:
```bash
rocklist=(
    "dockers/docker-database"
    "dockers/docker-sonic-mgmt-framework"
)
```

New:
```bash
rocklist=(
    "dockers/docker-database"
    "dockers/docker-sonic-mgmt-framework"
    "dockers/docker-eventd"
)
```

- [ ] **Step 3: Verify the change**

Run: `grep -A5 'rocklist=' build_rocks.sh`
Expected: All three containers in the list.

- [ ] **Step 4: Commit**

```bash
git add build_rocks.sh
git commit -m "build: add docker-eventd to build_rocks.sh rocklist"
```

---

### Task 4: Docker path regression verification

**Files:**
- No file changes. Verification only.

- [ ] **Step 1: Build the Docker image**

Run:
```bash
make SONIC_BUILD_JOBS=4 target/docker-eventd.gz
```

Expected: Build completes successfully. The pebble detection in `start.sh` does not affect the Docker path because `pgrep -x pebble` returns false in a supervisord container.

- [ ] **Step 2: If build fails, investigate**

If the build fails, check:
- `start.sh` syntax: `bash -n dockers/docker-eventd/start.sh`
- No other files were accidentally modified: `git diff --stat`

- [ ] **Step 3: Record result**

---

### Task 5: Rock build verification

**Files:**
- No file changes. Verification only.

**Prerequisites:**
- Task 4 completed
- `make` has been run
- `build_rocks.sh` handles docker-database, docker-sonic-mgmt-framework, and docker-eventd

- [ ] **Step 1: Run build_rocks.sh**

Run:
```bash
./build_rocks.sh
```

Expected: `target/docker-eventd.gz` is generated.

If docker-eventd fails, check:
- Missing deb files
- Missing wheel files
- Package resolution errors
- j2 rendering errors (check that `j2` is available and `rsyslog_plugin.conf.j2` is staged)

- [ ] **Step 2: Load the rock image**

Run:
```bash
docker load -i target/docker-eventd.gz
```

- [ ] **Step 3: Run the container**

Run:
```bash
docker container stop eventd_rock 2>/dev/null || true
docker container rm eventd_rock 2>/dev/null || true
docker run -d --name eventd_rock \
  -t --security-opt apparmor=unconfined --security-opt="systempaths=unconfined" \
  -v /etc/sonic:/etc/sonic:ro -v /etc/localtime:/etc/localtime:ro \
  docker-eventd:latest
```

- [ ] **Step 4: Verify pebble and services are running**

Run:
```bash
docker exec eventd_rock pgrep -x pebble
docker exec eventd_rock pgrep -x rsyslogd
docker exec eventd_rock pgrep -x eventd
```

Expected: All three commands output PIDs (non-empty).

- [ ] **Step 5: Check pebble logs for errors**

Run:
```bash
docker exec eventd_rock pebble logs
```

Expected: No ImportError, missing shared library, or crash errors.

- [ ] **Step 6: Verify rsyslog plugin conf files exist**

Run:
```bash
docker exec eventd_rock ls /etc/rsyslog.d/rsyslog_plugin_conf/
```

Expected: `host_events.conf`, `bgp_events.conf`, `dhcp_relay_events.conf`, `swss_events.conf`, `syncd_events.conf` exist.

- [ ] **Step 7: Runtime state comparison**

Compare with existing `eventd` container (from Dockerfile):
```bash
docker exec eventd ps aux
docker exec eventd_rock ps aux
```

- [ ] **Step 8: Record results**

If issues are found, iterate by fixing `rockcraft.yaml` and re-running.
