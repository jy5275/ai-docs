# Rockcraft + Pebble Migration: docker-eventd on Resolute

**Date:** 2026-07-23
**Branch:** `202605_resolute_rock`
**Scope:** `dockers/docker-eventd` container only
**Reference:** `feature_noble_build` branch (Noble implementation), `dockers/docker-database` on Resolute (PR #5), `dockers/docker-sonic-mgmt-framework` on Resolute (completed)

## 1. Goal

Migrate the `docker-eventd` container's packaging from Dockerfile to Rockcraft and its in-container process manager from supervisord to Pebble, on the `202605_resolute` branch (Ubuntu 26.04).

Both the existing Dockerfile path and the new Rockcraft path must coexist in the same branch.

## 2. Scope Constraints

- **Only docker-eventd** — other containers are out of scope.
- **Not minimizing image size** — `base: ubuntu@26.04` (full Ubuntu runtime base) is acceptable.
- **Package names, not chisel slices** — full package names in `stage-packages`.

## 3. Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Rockcraft base | `base: ubuntu@26.04` | Full Ubuntu base, simpler; image size not a concern |
| start.sh coexistence | `pgrep -x pebble` detection | Consistent with docker-database and docker-sonic-mgmt-framework; both paths use same start.sh |
| supervisord in rock | Excluded | Rock path uses pebble; no supervisord packages, no `/var/log/supervisor`, no `supervisord.conf` in rock |
| Timezone commands in start.sh | Not included | Upstream removed these in 202405/202605; not needed in either path |
| deb filenames in rockcraft.yaml | Wildcards (`*_*.deb`) | Avoids hardcoding version numbers; resilient to dependency changes |
| rsyslog_plugin.conf.j2 rendering | In override-build | Dockerfile renders .conf files at build time using `j2 -f json`; rock must replicate this |
| eventdb service | Included | Resolute supervisord.conf has eventdb program; include for parity |
| No environment variables on services | None | DEBIAN_FRONTEND, IMAGENAME, DISTRO are build-time only |

## 4. Docker Layer Chain Analysis

```
ubuntu:resolute
  -> docker-base-resolute
  -> docker-config-engine-resolute
  -> docker-eventd
```

### 4.1 Layer 1: docker-base-resolute (FROM ubuntu:resolute)

**apt packages (runtime, not already in base ubuntu@26.04):**
rsyslog, rsyslog-relp, python3, redis-tools, iproute2, net-tools, jq, libzmq5, libwrap0, libatomic1, libdaemon0, libdbus-1-3, libjansson4

**pip packages:**
- `jinjanator` — needed (template rendering at build time)
- `supervisord-dependent-startup==1.4.0` — **not needed** (pebble replaces supervisord)

**SONiC debs:**
- `socat` — dpkg -x

**Config files:**
- `etc/rsyslog.conf` — needed (SONiC custom rsyslog config with omrelp forwarding)

### 4.2 Layer 2: docker-config-engine-resolute (FROM docker-base-resolute)

**apt packages:**
- `python3-redis` — needed
- `python3-yaml` — needed

**pip packages:**
- `pyangbind==0.8.7` — needed (runtime yang model processing)

**SONiC debs:**
- `libswsscommon` — dpkg -x
- `libyang3` — dpkg -x
- `python3-libyang` — dpkg -x
- `python3-swsscommon` — dpkg -x
- `sonic-db-cli` — dpkg -x
- `sonic-eventd` — dpkg -x
- `sonic-supervisord-utilities-rs` — **not needed** (supervisord related)

**Python wheels:**
- `sonic_py_common`, `sonic_yang_mgmt`, `sonic_yang_models`, `sonic_containercfgd`, `sonic_config_engine`
- `sonic_supervisord_utilities` — **not needed** (supervisord related)

**Files:**
- `files/swss_vars.j2` -> `/usr/share/sonic/templates/` — needed
- `files/readiness_probe.sh` -> `/usr/bin/` — needed
- `files/container_startup.py` -> `/usr/share/sonic/scripts/` — needed

### 4.3 Layer 3: docker-eventd (FROM docker-config-engine-resolute)

**apt packages:** None (no additional apt packages)

**pip packages:** None (no additional pip packages; `sonic_utilities` is a build dependency via `_INSTALL_PYTHON_WHEELS` but not installed in the container)

**SONiC debs:**
- `sonic-eventd` — dpkg -x (provides `/usr/bin/eventd`, `/usr/bin/eventdb`, `/usr/bin/events_tool`, `/usr/bin/events_publish_tool.py`, `/etc/evprofile/default.json`)

**Files:**
- `start.sh` -> `/usr/bin/` — needed
- `eventdb_wrapper.sh` -> `/usr/bin/` — needed
- `supervisord.conf` -> `/etc/supervisor/conf.d/` — **not needed** (pebble replaces supervisord)
- `critical_processes` -> `/etc/supervisor/` — **not needed** (supervisord related)
- `*.json` (event info) -> `/etc/rsyslog.d/rsyslog_plugin_conf/` — needed (for j2 rendering)
- `files/rsyslog_plugin.conf.j2` -> `/etc/rsyslog.d/rsyslog_plugin_conf/` — needed (for j2 rendering)

### 4.4 Runtime Dependencies

From docker-database migration testing:
- `libboost-serialization1.83.0` — needed by libswsscommon
- `libhiredis1.1.0` — needed by sonic-db-cli
- `libuuid1` — needed by libswsscommon
- `libxxhash0` — needed by libyang3

## 5. Pebble Services

Four pebble services, mirroring the four supervisord programs:

| Service | Command | startup | Notes |
|---------|---------|---------|-------|
| `rsyslogd` | `/usr/sbin/rsyslogd -n -iNONE` | enabled | System logger |
| `start` | `/usr/bin/start.sh` | enabled | Init script; on-success/on-failure: ignore (runs once) |
| `eventd` | `/usr/bin/eventd` | (not auto-started) | Event daemon; started by start.sh via `pebble start eventd` |
| `eventdb` | `/usr/bin/eventdb_wrapper.sh` | (not auto-started) | Event DB; started by start.sh via `pebble start eventdb` |

The `eventd` and `eventdb` services are not auto-started because they depend on `start` completing first. In the supervisord path, this was handled by `dependent_startup_wait_for=start:exited`. In the pebble path, `start.sh` explicitly calls `pebble start eventd` and `pebble start eventdb` after initialization.

No environment variables are set on any service. `RUNTIME_OWNER` is injected at container start by `docker_image_ctl.j2` (`-e RUNTIME_OWNER=local`).

## 6. start.sh Coexistence Design

The existing `start.sh` is modified to detect whether pebble is running and branch into pebble-specific logic at the end. This follows the same pattern as docker-database and docker-sonic-mgmt-framework.

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

**Docker path (supervisord):** `pgrep -x pebble` returns false. Only executes the `RUNTIME_OWNER` default. eventd and eventdb are started by supervisord's `dependent_startup_wait_for=start:exited`.

**Rock path (pebble):** `pgrep -x pebble` returns true. Loads syslog layer, replans, then starts eventd and eventdb via pebble.

## 7. rockcraft.yaml

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

### 7.1 Design Notes

- **deb wildcards:** SONiC deb filenames use wildcards (e.g., `socat_*.deb`).
- **python plugin:** Python wheels and pip packages installed via dedicated `install-python` part.
- **rsyslog_plugin.conf.j2 rendering:** The Dockerfile renders `.conf` files at build time using `j2 -f json` from the `.j2` template and `*_events_info.json` data files. The rock replicates this in `override-build` — after `craftctl default` copies the source files, the j2 commands render the `.conf` files, then the `.j2` and `.json` source files are deleted. The `j2` tool is provided by the `jinjanator` pip package (installed in the build-base environment).
- **rsyslog.conf and manifest.json in override-prime:** Copied in override-prime (not organize) — rsyslog.conf because stage-package `rsyslog` overwrites with its default config; manifest.json because it needs to be at the rock root.
- **No supervisord:** The rock does not install supervisord packages or include `supervisord.conf`/`critical_processes`.
- **add-user part:** Creates the `syslog` user/group needed by rsyslog.
- **eventdb service:** Included for parity with Resolute supervisord.conf. Uses `eventdb_wrapper.sh` which conditionally starts `/usr/bin/eventdb` based on `/etc/evprofile/default.json`. `on-success: ignore` / `on-failure: ignore` because it may exit 0 when events list is empty.
- **sonic-rsyslog-plugin:** NOT included in the rock. This deb is installed on the HOST (via `sonic_debian_extension.j2`), not in the container. The container only generates `.conf` files that the host's rsyslog uses to call the host's `rsyslog_plugin` binary.
- **sonic_utilities:** NOT included in the rock. It's a build dependency (`_INSTALL_PYTHON_WHEELS`) but not installed in the Docker container and not needed at runtime.

## 8. Files to Create / Modify

### 8.1 New Files

| File | Description |
|------|-------------|
| `dockers/docker-eventd/rockcraft.yaml` | Rockcraft manifest (see section 7) |

### 8.2 Modified Files

| File | Change |
|------|--------|
| `dockers/docker-eventd/start.sh` | Add pebble detection and orchestration (see section 6) |
| `build_rocks.sh` | Add `"dockers/docker-eventd"` to rocklist |

### 8.3 Unmodified Files

| File | Reason |
|------|--------|
| `Dockerfile.j2` | Docker path unchanged (coexistence) |
| `supervisord.conf` | Docker path unchanged; not used in rock |
| `eventdb_wrapper.sh` | Shared between both paths, no change needed |
| `critical_processes` | Docker path only; not used in rock |
| `*.json` (event info) | Shared between both paths, no change needed |
| `rules/docker-eventd.mk` | No change |
| `rules/scripts.mk` | Already updated by docker-database migration |
| `files/build_templates/docker_image_ctl.j2` | Already supports pebble detection |

## 9. Shared Infrastructure (from docker-database migration)

- `files/rsyslog/syslog-layer.yaml` — Pebble syslog layer template
- `dockers/docker-base-resolute/etc/rsyslog.conf` — SONiC custom rsyslog config
- `rules/scripts.mk` — `RSYSLOG_CONF`, `RSYSLOG_PEBBLE_LAYER`, `RSYSLOG_PLUGIN_CONF_J2` in `SONIC_COPY_FILES`
- `files/build_templates/docker_image_ctl.j2` — pebble + supervisord dual detection
- `build_rocks.sh` — staging logic (`cp -r target/files/resolute/*`, etc.)

## 10. Verification

### 10.1 Docker Path Regression

```bash
make SONIC_BUILD_JOBS=4 target/docker-eventd.gz
```

### 10.2 Rock Build

```bash
./build_rocks.sh
```

Verify:
- `target/docker-eventd.gz` is generated
- `docker load -i target/docker-eventd.gz` succeeds
- Container starts
- `docker exec eventd_rock pgrep -x pebble` — pebble running
- `docker exec eventd_rock pgrep -x rsyslogd` — rsyslogd running
- `docker exec eventd_rock pgrep -x eventd` — eventd running
- `pebble logs` shows no ImportError or missing shared library errors

### 10.3 Runtime State Comparison

Compare with existing `eventd` container (from Dockerfile):
- Process list: rsyslogd and eventd both running
- Key file locations: `/usr/bin/start.sh`, `/usr/bin/eventdb_wrapper.sh`, `/usr/bin/eventd`, `/etc/rsyslog.d/rsyslog_plugin_conf/*.conf`
