# Rockcraft + Pebble Migration: docker-sonic-mgmt-framework on Resolute

**Date:** 2026-07-23
**Branch:** `202605_resolute_rock`
**Scope:** `dockers/docker-sonic-mgmt-framework` container only
**Reference:** `feature_noble_build` branch (Noble implementation), `dockers/docker-database` on Resolute (PR #5)

## 1. Goal

Migrate the `docker-sonic-mgmt-framework` container's packaging from Dockerfile to Rockcraft and its in-container process manager from supervisord to Pebble, on the `202605_resolute` branch (Ubuntu 26.04).

Both the existing Dockerfile path and the new Rockcraft path must coexist in the same branch.

## 2. Scope Constraints

- **Only docker-sonic-mgmt-framework** — other containers are out of scope.
- **VS/single-ASIC only** — static pebble services, no dynamic multi-ASIC generation.
- **Not minimizing image size** — `base: ubuntu@26.04` (full Ubuntu runtime base) is acceptable.
- **Package names, not chisel slices** — unlike docker-database (which uses chisel slices), this container uses full package names in `stage-packages`.

## 3. Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Rockcraft base | `base: ubuntu@26.04` | Full Ubuntu base, simpler; image size not a concern |
| start.sh coexistence | `pgrep -x pebble` detection | Consistent with docker-database; both paths use same start.sh |
| supervisord in rock | Excluded | Rock path uses pebble; no supervisord packages, no `/var/log/supervisor`, no `supervisord.conf` in rock |
| Timezone commands in start.sh | Not included | Upstream removed these in 202405/202605; not needed in either path |
| Volume mount in .mk | Unchanged | Keep `/etc/localtime:/etc/localtime:ro` as-is |
| deb filenames in rockcraft.yaml | Wildcards (`*_*.deb`) | Avoids hardcoding version numbers; resilient to dependency changes |

## 4. Docker Layer Chain Analysis

The container inherits a three-layer Docker chain that must be flattened into a single `rockcraft.yaml`:

```
ubuntu:resolute
  -> docker-base-resolute
  -> docker-config-engine-resolute
  -> docker-sonic-mgmt-framework
```

### 4.1 Layer 1: docker-base-resolute (FROM ubuntu:resolute)

**apt packages (runtime):**
curl, less, perl, procps, python3, python3-pip, python3-setuptools, python3-wheel, python-is-python3, vim-tiny, rsyslog, rsyslog-relp, rsync, redis-tools, libdaemon0, libdbus-1-3, libjansson4, iproute2, net-tools, jq, libzmq5, libwrap0, libatomic1

**pip packages:**
- `jinjanator` — needed (template rendering)
- `supervisord-dependent-startup==1.4.0` — **not needed** (pebble replaces supervisord)

**SONiC debs:**
- `socat` — dpkg -x

**Config files:**
- `etc/rsyslog.conf` — needed (SONiC custom rsyslog config with omrelp forwarding)
- `etc/rsyslog.d/supervisor.conf` — **not needed** (supervisord related)
- `etc/supervisor/supervisord.conf` — **not needed** (pebble replaces supervisord)
- `pip.conf` — needed (pip install in rock build)

### 4.2 Layer 2: docker-config-engine-resolute (FROM docker-base-resolute)

**apt packages:**
- `apt-utils, build-essential, python3-dev` — **not needed** (build-time only, purged in Dockerfile)
- `python3-cffi` — **not needed** (build-time)
- `python3-redis` — needed
- `python3-yaml` — needed

**pip packages:**
- `pyangbind==0.8.7` (then uninstall enum34) — needed (runtime yang model processing)

**SONiC debs:**
- `libswsscommon` — dpkg -x
- `libyang3` — dpkg -x
- `python3-libyang` (libyang3-py3) — dpkg -x
- `python3-swsscommon` — dpkg -x
- `sonic-db-cli` — dpkg -x
- `sonic-eventd` — dpkg -x
- `sonic-supervisord-utilities-rs` — **not needed** (supervisord related)

**Python wheels:**
- `sonic_py_common` — pip install
- `sonic_yang_mgmt` — pip install
- `sonic_yang_models` — pip install
- `sonic_containercfgd` — pip install
- `sonic_config_engine` — pip install
- `sonic_supervisord_utilities` — **not needed** (supervisord related)

**Files:**
- `files/swss_vars.j2` -> `/usr/share/sonic/templates/` — needed
- `files/readiness_probe.sh` -> `/usr/bin/` — needed
- `files/container_startup.py` -> `/usr/share/sonic/scripts/` — needed

### 4.3 Layer 3: docker-sonic-mgmt-framework (FROM docker-config-engine-resolute)

**apt packages:**
- `g++, python3-dev` — **not needed** (build-time only, removed in Dockerfile)
- `libxml2-16` — needed (REST server dependency)
- `libcurl4t64` — needed (REST server dependency)
- `libcjson1` — needed (REST server dependency)

**pip packages:**
- `requests` — needed
- `urllib3` — needed

**SONiC debs:**
- `sonic-mgmt-common` — dpkg -x
- `sonic-mgmt-framework` — dpkg -x

**Files:**
- `start.sh` -> `/usr/bin/` — needed
- `rest-server.sh` -> `/usr/bin/` — needed
- `mgmt_vars.j2` -> `/usr/share/sonic/templates/` — needed
- `supervisord.conf` -> `/etc/supervisor/conf.d/` — **not needed** (pebble replaces supervisord)

### 4.4 Runtime Dependencies

The following packages were identified as runtime dependencies during docker-database migration testing and are needed here too:
- `libboost-serialization1.83.0` — needed by libswsscommon
- `libhiredis1.1.0` — needed by sonic-db-cli
- `libuuid1` — needed by libswsscommon
- `libxxhash0` — needed by libyang3

## 5. Pebble Services

Three pebble services, mirroring the three supervisord programs:

| Service | Command | startup | Notes |
|---------|---------|---------|-------|
| `rsyslogd` | `/usr/sbin/rsyslogd -n -iNONE` | enabled | System logger |
| `start` | `/usr/bin/start.sh` | enabled | Init script; on-success/on-failure: ignore (runs once) |
| `rest-server` | `/usr/bin/rest-server.sh` | (not auto-started) | REST API server; started by start.sh via `pebble start rest-server` |

The `rest-server` service is not auto-started because it depends on `start` completing first. In the supervisord path, this was handled by `dependent_startup_wait_for=start:exited`. In the pebble path, `start.sh` explicitly calls `pebble start rest-server` after initialization.

No environment variables are set on any service. The Dockerfile's `ENV DEBIAN_FRONTEND=noninteractive` is a build-time concern (prevents apt-get interactive prompts during image build); none of the runtime services run apt-get. `IMAGENAME` and `DISTRO` are Docker build-graph variables, not runtime variables. rsyslogd does need `CONTAINER_NAME`, but that is injected at container start by `docker_image_ctl.j2` (`--env "CONTAINER_NAME"=$DOCKERNAME`), not by the rock's service definition.

## 6. start.sh Coexistence Design

The existing `start.sh` is modified to detect whether pebble is running and branch into pebble-specific logic at the end. This follows the same pattern as docker-database's merged init script.

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

**Docker path (supervisord):** `pgrep -x pebble` returns false. Only executes `mkdir -p /var/sonic` and `echo`. rest-server is started by supervisord's `dependent_startup_wait_for=start:exited`.

**Rock path (pebble):** `pgrep -x pebble` returns true. Loads syslog layer, replans, then starts rest-server via pebble.

Note: Timezone symlink commands (`TZ=$(cat /etc/timezone)`, `ln -sf /usr/share/zoneinfo/$TZ /etc/localtime`) are NOT included. These were added then removed in upstream 202405/202605 branches and are not needed in either path.

Note: The `envs` file (generated by `build_rocks.sh` with `export IMAGE_VERSION=...`) is NOT sourced in start.sh. `IMAGE_VERSION` is a Docker build-graph variable (`--build-arg image_version=$(SONIC_IMAGE_VERSION)` in `slave.mk`), not a runtime variable. No script in docker-sonic-mgmt-framework references `IMAGE_VERSION` at runtime.

## 7. rockcraft.yaml

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

### 7.1 Design Notes

- **deb wildcards:** SONiC deb filenames use wildcards (e.g., `socat_*.deb`) instead of hardcoded version numbers, making the rockcraft.yaml resilient to dependency version changes.
- **python plugin:** Python wheels and pip packages are installed via a dedicated `install-python` part using rockcraft's `python` plugin, which creates a virtualenv and manages the installation automatically. This follows the Noble implementation pattern. The `python` and `dump` plugins cannot coexist in the same part, so a separate part is required. `stage-packages: [python3-venv]` provides the venv support needed by the plugin.
- **No stage filter:** Unlike docker-database, no `stage` filter is used. Image size is not a concern for this container; all staged content passes through to the prime step.
- **rsyslog.conf and manifest.json in override-prime:** Both are copied in override-prime (not organize) — rsyslog.conf because stage-package `rsyslog` overwrites the organize step's copy with its default config; manifest.json because it needs to be at the rock root.
- **No supervisord:** The rock does not install `supervisor`, `supervisord-dependent-startup`, `sonic-supervisord-utilities-rs`, or `sonic_supervisord_utilities`. It does not include `supervisord.conf` or create `/var/log/supervisor`.
- **add-user part:** Creates the `syslog` user/group needed by rsyslog. Uses overlay-script with `groupadd -R` / `useradd -R` to modify the overlay's passwd/group files.

## 8. Files to Create / Modify

### 8.1 New Files

| File | Description |
|------|-------------|
| `dockers/docker-sonic-mgmt-framework/rockcraft.yaml` | Rockcraft manifest (see section 7) |

### 8.2 Modified Files

| File | Change |
|------|--------|
| `dockers/docker-sonic-mgmt-framework/start.sh` | Add pebble detection and orchestration (see section 6) |
| `build_rocks.sh` | Add `"dockers/docker-sonic-mgmt-framework"` to rocklist; add `-r` flag to `cp` for directory staging |

### 8.3 Unmodified Files

| File | Reason |
|------|--------|
| `Dockerfile.j2` | Docker path unchanged (coexistence) |
| `supervisord.conf` | Docker path unchanged; not used in rock |
| `rest-server.sh` | Shared between both paths, no change needed |
| `mgmt_vars.j2` | No change |
| `rules/docker-sonic-mgmt-framework.mk` | No change (volume mount stays as-is) |
| `rules/scripts.mk` | Already updated by docker-database migration |
| `rules/scripts.dep` | Already updated by docker-database migration |
| `files/build_templates/docker_image_ctl.j2` | Already supports pebble detection |

## 9. Shared Infrastructure (from docker-database migration)

The following infrastructure was already established by the docker-database migration (PR #5) and is reused:

- `files/rsyslog/syslog-layer.yaml` — Pebble syslog layer template
- `dockers/docker-base-resolute/etc/rsyslog.conf` — SONiC custom rsyslog config (registered as `$(RSYSLOG_CONF)` in rules/scripts.mk)
- `rules/scripts.mk` — `RSYSLOG_CONF` and `RSYSLOG_PEBBLE_LAYER` variables, added to `SONIC_COPY_FILES`
- `rules/docker-config-engine-resolute.mk` — `$(RSYSLOG_CONF)` and `$(RSYSLOG_PEBBLE_LAYER)` in `_FILES`
- `files/build_templates/docker_image_ctl.j2` — pebble + supervisord dual detection
- `build_rocks.sh` — staging logic (`cp -r target/files/resolute/*`, `cp target/debs/resolute/*.deb`, `cp target/python-wheels/resolute/*.whl`)

## 10. Verification

### 10.1 Docker Path Regression

```bash
make SONIC_BUILD_JOBS=4 target/docker-sonic-mgmt-framework.gz
```

Confirm the Dockerfile path still builds successfully. start.sh's USE_PEBBLE detection in a supervisord container will take the original path (pgrep pebble returns false).

### 10.2 Rock Build

```bash
# After make completes
./build_rocks.sh
```

Verify:
- `target/docker-sonic-mgmt-framework.gz` is generated
- `docker load -i target/docker-sonic-mgmt-framework.gz` succeeds
- Container starts: `docker run -d --name mgmt-framework_rock ... docker-sonic-mgmt-framework:latest`
- `docker exec mgmt-framework_rock pgrep -x pebble` — pebble running
- `docker exec mgmt-framework_rock pgrep -x rsyslogd` — rsyslogd running
- `docker exec mgmt-framework_rock pgrep -f rest_server` — rest-server running
- `pebble logs` shows no ImportError or missing shared library errors

### 10.3 Runtime State Comparison

An existing `mgmt-framework` container built from the current Dockerfile is running in the environment. After migration, the rock-based container's runtime state should match:

- Process list: rsyslogd and rest_server both running
- Installed packages: `dpkg -l` output matches
- Key file locations: `/usr/bin/start.sh`, `/usr/bin/rest-server.sh`, `/usr/share/sonic/templates/mgmt_vars.j2`, `/usr/sbin/rest_server`, etc.
