# docker-router-advertiser Rockcraft + Pebble Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate docker-router-advertiser from Dockerfile + supervisord to Rockcraft + Pebble on the `202605_resolute_rock` branch, with both paths coexisting in the same branch.

**Architecture:** Flatten the three-layer Docker inheritance chain (`docker-base-resolute` → `docker-config-engine-resolute` → `docker-router-advertiser`) into a single `rockcraft.yaml`. Use Approach A (static services + start.sh on-demand start): enumerate `rsyslogd`, `start`, `wait_for_link`, and `radvd` in the `services` section; `start.sh`'s pebble branch renders `radvd.conf.j2` and `wait_for_link.sh.j2` at runtime, then conditionally starts `wait_for_link` and `radvd` only when the container is a ToR with VLAN IPv6 addresses.

**Tech Stack:** Rockcraft (ubuntu@26.04 base), Pebble service manager, SONiC sonic-cfggen / sonic-db-cli, radvd daemon, Jinja2 templates.

## Global Constraints

Copied verbatim from the meta-spec (`docs/2026-07-27-rockcraft-pebble-resolute-containers-migration-meta-spec-en.md`):

- Rockcraft base: `base: ubuntu@26.04`
- build-base: `build-base: ubuntu@26.04`
- stage-packages: package names (not chisel slices)
- build-packages: build-only tools (python3-pip, git, gcc, make); must not enter the runtime image
- start.sh coexistence: `pgrep -x pebble` detection; both paths share same start.sh
- supervisord in rock: Excluded — no supervisord packages, configs, or directories
- Timezone commands in start.sh: Not included
- deb filenames in rockcraft.yaml: Wildcards (`*_*.deb`)
- Environment variables on services: None (no DEBIAN_FRONTEND/IMAGENAME/DISTRO)
- Stage filter (prime): Not used
- Docker path (Dockerfile.j2, supervisord.conf.j2, critical_processes, docker-init.sh): Unchanged — coexistence
- rules/docker-router-advertiser.mk: No change
- rules/scripts.mk: No change (already updated by docker-database migration)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `dockers/docker-router-advertiser/rockcraft.yaml` | Create | Rockcraft manifest: services, parts (setup-router-advertiser, install-python, add-user), stage-packages, organize |
| `dockers/docker-router-advertiser/start.sh` | Modify | Append pebble detection branch after existing init logic |
| `build_rocks.sh` | Modify | Append `"dockers/docker-router-advertiser"` to rocklist array |

**Unmodified files (Docker path coexistence):**

| File | Reason |
|------|--------|
| `Dockerfile.j2` / `Dockerfile` / `Dockerfile.cleanup` | Docker path unchanged |
| `docker-router-advertiser.supervisord.conf.j2` | Docker path only; not used in rock |
| `critical_processes` | Docker path only; not used in rock |
| `docker-init.sh` | Docker path only; not used in rock |
| `radvd.conf.j2` | Shared by both paths; organized into templates by rockcraft |
| `wait_for_link.sh.j2` | Shared by both paths; organized into templates by rockcraft |
| `rules/docker-router-advertiser.mk` | No change |
| `rules/docker-router-advertiser.dep` | No change |
| `manifest.json` | Copied to rock root by override-prime; content unchanged |

---

## Background: How the Docker Path Works Today

The current `docker-init.sh` (entrypoint) does three things at container startup:

1. Renders `docker-router-advertiser.supervisord.conf.j2` → `/etc/supervisor/conf.d/supervisord.conf` via `sonic-cfggen -d`. This Jinja2 template conditionally includes `wait_for_link` and `radvd` program blocks **only** when the device is a ToR (T0) with at least one VLAN interface that has an IPv6 address.
2. Renders `radvd.conf.j2` → `/etc/radvd.conf` via `sonic-cfggen -d`.
3. Renders `wait_for_link.sh.j2` → `/usr/bin/wait_for_link.sh` via `sonic-cfggen -d`, then `chmod +x`.

Then it `exec supervisord`, which starts `rsyslogd` and `start.sh`. The `start.sh` script calls `container_startup.py`. Supervisord's `dependent_startup_wait_for` chain starts `wait_for_link` (after `start` exits), then `radvd` (after `wait_for_link` exits) — but only if the conditional blocks were rendered.

**The Rock path replaces all of this with:**
- Pebble services declared statically in `rockcraft.yaml` (all daemons default-disabled except `rsyslogd` and `start`)
- `start.sh`'s pebble branch: renders `radvd.conf.j2` and `wait_for_link.sh.j2` via `sonic-cfggen -d`, checks the ToR+VLAN-IPv6 condition at runtime, then conditionally `pebble start wait_for_link` and `pebble start radvd`

The `supervisord.conf.j2` template is **not needed** in the rock path because services are declared in `rockcraft.yaml` and the conditional logic moves to `start.sh`.

---

## Task 1: Create rockcraft.yaml

**Files:**
- Create: `dockers/docker-router-advertiser/rockcraft.yaml`

**Interfaces:**
- Consumes: Shared files copied by `build_rocks.sh` from `target/files/resolute/` → `files/` (syslog-layer.yaml, swss_vars.j2, readiness_probe.sh, container_startup.py, rsyslog.conf). SONiC debs from `target/debs/resolute/` → `debs/`. Python wheels from `target/python-wheels/resolute/` → `python-wheels/`.
- Produces: A buildable `rockcraft.yaml` that `rockcraft pack` turns into `docker-router-advertiser_1.0.0_amd64.rock`.

- [ ] **Step 1: Create the rockcraft.yaml file**

Create `dockers/docker-router-advertiser/rockcraft.yaml` with this exact content:

```yaml
name: docker-router-advertiser
summary: SONiC router advertiser container
description: A rock for SONiC router advertiser container
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
  wait_for_link:
    command: /usr/bin/wait_for_link.sh
    override: replace
    on-success: ignore
    on-failure: ignore
  radvd:
    command: /usr/sbin/radvd -n
    override: replace

parts:
  setup-router-advertiser:
    plugin: dump
    source: .
    build-packages:
      - python3-pip
    override-build: |
      craftctl default

      pip install --break-system-packages jinjanator

      # Install SONiC debs (wildcard filenames)
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
      dpkg -x debs/sonic-supervisord-utilities-rs_*.deb ${CRAFT_PART_INSTALL}

      # Clean up deb/wheel source files
      rm -rf ${CRAFT_PART_INSTALL}/debs ${CRAFT_PART_INSTALL}/python-wheels

    organize:
      start.sh: usr/bin/start.sh
      radvd.conf.j2: usr/share/sonic/templates/radvd.conf.j2
      wait_for_link.sh.j2: usr/share/sonic/templates/wait_for_link.sh.j2
      files/syslog-layer.yaml: usr/share/sonic/templates/syslog-layer.yaml
      files/swss_vars.j2: usr/share/sonic/templates/swss_vars.j2
      files/readiness_probe.sh: usr/bin/readiness_probe.sh
      files/container_startup.py: usr/share/sonic/scripts/container_startup.py

    stage-packages:
      # Base runtime packages (inherited from config-engine layer)
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
      # SONiC deb runtime dependencies
      - libboost-serialization1.83.0
      - libhiredis1.1.0
      - libuuid1
      - libxxhash0
      # Container-specific packages
      - radvd

    override-prime: |
      craftctl default

      cp ${CRAFT_PROJECT_DIR}/files/rsyslog.conf etc/rsyslog.conf
      cp ${CRAFT_PROJECT_DIR}/manifest.json manifest.json

  install-python:
    plugin: python
    source: .
    python-packages:
      # config-engine inherited SONiC wheels
      - ./python-wheels/sonic_py_common-1.0-py3-none-any.whl
      - ./python-wheels/sonic_yang_mgmt-1.0-py3-none-any.whl
      - ./python-wheels/sonic_yang_models-1.0-py3-none-any.whl
      - ./python-wheels/sonic_containercfgd-1.0-py3-none-any.whl
      - ./python-wheels/sonic_config_engine-1.0-py3-none-any.whl
      # common pip packages
      - jinjanator
      - click
      - pyangbind==0.8.7
      - lxml
    stage-packages:
      - python3-venv

  add-user:
    plugin: nil
    after: [setup-router-advertiser]
    overlay-script: |
      groupadd -R $CRAFT_OVERLAY syslog
      useradd -R $CRAFT_OVERLAY -M -r --system -g adm syslog
    prime:
      - etc/passwd
      - etc/group
```

**Key design decisions for this rockcraft.yaml:**

1. **services section** — Four services following Approach A (meta-spec section 7.1):
   - `rsyslogd`: `startup: enabled` (auto-start)
   - `start`: `startup: enabled`, `on-success: ignore`, `on-failure: ignore` (auto-start, no restart after exit)
   - `wait_for_link`: no `startup` key (default disabled, started by start.sh)
   - `radvd`: no `startup` key (default disabled, started by start.sh)
   - `wait_for_link` has `on-success: ignore` / `on-failure: ignore` because it is a one-shot script that exits after interfaces are ready

2. **debs installed** — Same as docker-eventd (inherited from config-engine layer): `socat`, `libswsscommon`, `libyang3`, `python3-libyang`, `python3-swsscommon`, `sonic-db-cli`, `sonic-eventd`, `libnl-*` family, `sonic-supervisord-utilities-rs`. The docker-router-advertiser Dockerfile.j2 has no container-specific debs (`docker_router_advertiser_debs` is empty — it only installs `radvd` via `apt-get`). The config-engine layer's debs are the only SONiC-built debs needed.

3. **stage-packages** — Base config-engine packages (identical to docker-eventd) plus `radvd` (the container-specific daemon, originally installed via `apt-get -y install radvd` in Dockerfile.j2 line 19).

4. **organize** — Places `start.sh`, `radvd.conf.j2`, `wait_for_link.sh.j2`, and shared files (`syslog-layer.yaml`, `swss_vars.j2`, `readiness_probe.sh`, `container_startup.py`) into their runtime paths. The `.j2` templates go to `usr/share/sonic/templates/` where `sonic-cfggen` expects them (same path as Dockerfile.j2 line 31 copies them).

5. **override-prime** — Copies `rsyslog.conf` (overwritten by stage-package's default) and `manifest.json` (must be at rock root), same as docker-eventd.

6. **install-python** — Identical to docker-eventd: config-engine wheels + common pip packages. Router-advertiser has no container-specific Python wheels.

7. **add-user** — Creates `syslog` user/group for rsyslog, identical to docker-eventd.

8. **No supervisord.conf.j2 in organize** — The rock path does not use supervisord. The `docker-router-advertiser.supervisord.conf.j2` template stays in the source directory but is not organized into the rock. It remains for the Docker path only.

- [ ] **Step 2: Verify the file was created correctly**

Run: `cat dockers/docker-router-advertiser/rockcraft.yaml | head -5`
Expected: Shows `name: docker-router-advertiser` and `summary: SONiC router advertiser container`

- [ ] **Step 3: Commit**

```bash
git add dockers/docker-router-advertiser/rockcraft.yaml
git commit -m "build: add rockcraft.yaml for docker-router-advertiser

Create rockcraft.yaml following the docker-eventd pattern (meta-spec
section 5 skeleton). Flattens the docker-base-resolute ->
docker-config-engine-resolute -> docker-router-advertiser inheritance
chain into a single rock. Uses Approach A: rsyslogd and start are
auto-started; wait_for_link and radvd are default-disabled, started
conditionally by start.sh's pebble branch."
```

---

## Task 2: Modify start.sh — Append Pebble Branch

**Files:**
- Modify: `dockers/docker-router-advertiser/start.sh`

**Interfaces:**
- Consumes: `sonic-cfggen` (from config-engine wheels), `sonic-db-cli` (from debs), pebble (runtime), templates at `/usr/share/sonic/templates/` (radvd.conf.j2, wait_for_link.sh.j2, syslog-layer.yaml)
- Produces: A start.sh that works in both Docker (supervisord) and Rock (pebble) paths. In the Rock path, it renders radvd.conf and wait_for_link.sh, checks the ToR+VLAN-IPv6 condition, and conditionally starts wait_for_link and radvd via `pebble start`.

**Existing start.sh content (preserved verbatim):**

```bash
#! /bin/bash

if [ "${RUNTIME_OWNER}" == "" ]; then
    RUNTIME_OWNER="kube"
fi

CTR_SCRIPT="/usr/share/sonic/scripts/container_startup.py"
if test -f ${CTR_SCRIPT}
then
    ${CTR_SCRIPT} -f radv -o ${RUNTIME_OWNER} -v ${IMAGE_VERSION}
fi
```

The existing logic (RUNTIME_OWNER default, container_startup.py call) stays unchanged. The pebble branch is appended after it.

**Pebble branch logic:**

The original `docker-init.sh` renders three templates via `sonic-cfggen -d`:
1. `docker-router-advertiser.supervisord.conf.j2` → supervisord config (not needed in rock path)
2. `radvd.conf.j2` → `/etc/radvd.conf`
3. `wait_for_link.sh.j2` → `/usr/bin/wait_for_link.sh` (then chmod +x)

The `supervisord.conf.j2` template contains the conditional logic that determines whether `wait_for_link` and `radvd` should run: it checks if `DEVICE_METADATA.localhost.type` contains "ToRRouter" or is "EPMS" or "MgsTsToR", and if any `VLAN_INTERFACE` has an IPv6 prefix. If so, the `wait_for_link` and `radvd` program blocks are included.

In the Rock path, this conditional logic moves to `start.sh`. Instead of rendering supervisord config, `start.sh` directly checks the same condition and calls `pebble start` accordingly. The `radvd.conf.j2` and `wait_for_link.sh.j2` templates are still rendered to their runtime locations.

- [ ] **Step 1: Modify start.sh**

Replace the entire content of `dockers/docker-router-advertiser/start.sh` with:

```bash
#! /bin/bash

if [ "${RUNTIME_OWNER}" == "" ]; then
    RUNTIME_OWNER="kube"
fi

CTR_SCRIPT="/usr/share/sonic/scripts/container_startup.py"
if test -f ${CTR_SCRIPT}
then
    ${CTR_SCRIPT} -f radv -o ${RUNTIME_OWNER} -v ${IMAGE_VERSION}
fi

if pgrep -x pebble > /dev/null 2>&1; then
    LAYER_FILE="/usr/share/sonic/templates/syslog-layer.yaml"
    pebble add syslog-layer --combine $LAYER_FILE
    pebble replan

    # Render radvd config and wait_for_link script from Jinja2 templates
    sonic-cfggen -d -t /usr/share/sonic/templates/radvd.conf.j2 > /etc/radvd.conf
    sonic-cfggen -d -t /usr/share/sonic/templates/wait_for_link.sh.j2 > /usr/bin/wait_for_link.sh
    chmod +x /usr/bin/wait_for_link.sh

    # Router advertiser should only run on ToR (T0) devices which have
    # at least one VLAN interface with an IPv6 address assigned.
    # Same condition as docker-router-advertiser.supervisord.conf.j2 lines 48-60.
    # Uses sonic-db-cli to query CONFIG_DB directly (robust, no Jinja2 one-liner).
    DEVICE_TYPE=$(sonic-db-cli CONFIG_DB HGET "DEVICE_METADATA|localhost" "type" 2>/dev/null)
    START_RADVD=false
    if echo "${DEVICE_TYPE}" | grep -qE "ToRRouter|EPMS|MgmtTsToR"; then
        for key in $(sonic-db-cli CONFIG_DB KEYS "VLAN_INTERFACE|*" 2>/dev/null); do
            # VLAN_INTERFACE keys: VLAN_INTERFACE|Vlan1000 or VLAN_INTERFACE|Vlan1000|fc02:1000::1/64
            # IPv6 prefixes contain ":" — check the third field
            prefix=$(echo "$key" | cut -d'|' -f3-)
            if echo "$prefix" | grep -q ":"; then
                START_RADVD=true
                break
            fi
        done
    fi

    if [ "${START_RADVD}" = "true" ]; then
        pebble start wait_for_link
        pebble start radvd
    fi
fi
```

**Explanation of the pebble branch:**

1. `pebble add syslog-layer --combine` — loads the syslog layer (same as all containers, meta-spec section 6)
2. `pebble replan` — applies the syslog layer
3. `sonic-cfggen -d -t radvd.conf.j2 > /etc/radvd.conf` — renders the radvd config file (same as docker-init.sh line 10-11)
4. `sonic-cfggen -d -t wait_for_link.sh.j2 > /usr/bin/wait_for_link.sh` — renders the wait_for_link script (same as docker-init.sh line 11-12)
5. `chmod +x /usr/bin/wait_for_link.sh` — makes it executable (same as docker-init.sh line 15)
6. The `START_RADVD` check replicates the Jinja2 conditional from `docker-router-advertiser.supervisord.conf.j2` lines 48-60. It queries CONFIG_DB via `sonic-db-cli`:
   - Gets `DEVICE_METADATA|localhost` `type` field
   - Checks if it contains `ToRRouter`, `EPMS`, or `MgmtTsToR` (same as the Jinja2 condition)
   - Iterates `VLAN_INTERFACE|*` keys and checks if any prefix (third `|`-delimited field) contains `:` (IPv6 addresses contain `:`; IPv4 do not)
   - If both conditions are true, sets `START_RADVD=true`
7. `pebble start wait_for_link` runs first, then `pebble start radvd` — this preserves the startup order from supervisord's `dependent_startup_wait_for` chain (wait_for_link after start exits, radvd after wait_for_link exits). `pebble start` is a one-shot command that blocks until the service starts, providing adequate ordering for `wait_for_link` which exits quickly.

**Why `sonic-db-cli` instead of `sonic-cfggen` for the condition check:**

The original `supervisord.conf.j2` uses Jinja2 filters (`pfx_filter`, `ipv6`) and `namespace()` to evaluate the condition at template rendering time. Replicating this as a `sonic-cfggen` one-liner is fragile because `sonic-cfggen` expects template files, not inline Jinja2 expressions. Querying CONFIG_DB directly with `sonic-db-cli` is more robust, more readable, and produces the same result: the `VLAN_INTERFACE` table keys with a third field containing `:` are exactly the IPv6 prefixes that `pfx_filter` + `ipv6` would match.

- [ ] **Step 2: Verify the file was modified correctly**

Run: `cat dockers/docker-router-advertiser/start.sh`
Expected: Shows the existing init logic followed by `if pgrep -x pebble > /dev/null 2>&1; then` block

Run: `bash -n dockers/docker-router-advertiser/start.sh`
Expected: No syntax errors (exit code 0)

- [ ] **Step 3: Commit**

```bash
git add dockers/docker-router-advertiser/start.sh
git commit -m "build: add pebble branch to docker-router-advertiser start.sh

Append pebble detection and orchestration block to start.sh. In the
rock path, renders radvd.conf.j2 and wait_for_link.sh.j2 via
sonic-cfggen, checks the ToR + VLAN IPv6 condition via sonic-db-cli
(same logic as supervisord.conf.j2), and conditionally starts
wait_for_link and radvd via pebble start. Docker path is unaffected
(pgrep -x pebble returns false in supervisord containers)."
```

---

## Task 3: Modify build_rocks.sh — Append to rocklist

**Files:**
- Modify: `build_rocks.sh`

**Interfaces:**
- Consumes: `dockers/docker-router-advertiser/rockcraft.yaml` (from Task 1)
- Produces: `build_rocks.sh` includes docker-router-advertiser in its rocklist, so `./build_rocks.sh` builds and packs it.

- [ ] **Step 1: Modify build_rocks.sh**

In `build_rocks.sh`, find the `rocklist` array (lines 4-8):

```bash
rocklist=(
    "dockers/docker-database"
    "dockers/docker-sonic-mgmt-framework"
    "dockers/docker-eventd"
)
```

Add `"dockers/docker-router-advertiser"` as the fourth entry:

```bash
rocklist=(
    "dockers/docker-database"
    "dockers/docker-sonic-mgmt-framework"
    "dockers/docker-eventd"
    "dockers/docker-router-advertiser"
)
```

- [ ] **Step 2: Verify the modification**

Run: `grep -A6 'rocklist=' build_rocks.sh`
Expected: Shows the array with `dockers/docker-router-advertiser` as the last entry

- [ ] **Step 3: Commit**

```bash
git add build_rocks.sh
git commit -m "build: add docker-router-advertiser to build_rocks.sh rocklist

Append dockers/docker-router-advertiser to the rocklist array so
./build_rocks.sh builds and packs the rock after the Docker path
target/ is populated."
```

---

## Task 4: Verify Rock Build

**Files:**
- No files modified — verification only

**Interfaces:**
- Consumes: All files from Tasks 1-3. Prerequisite: `make SONIC_BUILD_JOBS=4` has been run to populate `target/debs/resolute/`, `target/files/resolute/`, and `target/python-wheels/resolute/`.
- Produces: Confirmation that `rockcraft pack` succeeds and `docker load` works.

**Verification scope (per meta-spec section 10):** The goal is limited to successful rockcraft packing — confirming the rock builds, loads, and starts without packaging or shared-library errors. Full runtime verification (daemon functionality) is deferred to when a complete SONiC image is available.

- [ ] **Step 1: Verify prerequisite — target/ is populated**

Run: `ls target/debs/resolute/socat_*.deb target/debs/resolute/libswsscommon_*.deb target/debs/resolute/sonic-db-cli_*.deb target/python-wheels/resolute/sonic_config_engine-*.whl target/files/resolute/syslog-layer.yaml target/files/resolute/rsyslog.conf`
Expected: All files exist (no "No such file" errors)

If any files are missing, run `make SONIC_BUILD_JOBS=4` first (or at minimum the targets that produce the missing debs/wheels/files).

- [ ] **Step 2: Run build_rocks.sh (or rockcraft pack directly)**

Option A — full build_rocks.sh (builds all rocks including previously-migrated ones):
```bash
./build_rocks.sh
```

Option B — build only docker-router-advertiser (faster, for isolated testing):
```bash
cd dockers/docker-router-advertiser
mkdir -p debs files python-wheels
cp ../../target/debs/resolute/*.deb debs/
cp -r ../../target/files/resolute/* files/
cp ../../target/python-wheels/resolute/*.whl python-wheels/
echo "export IMAGE_VERSION=$(git rev-parse --abbrev-ref HEAD)-$(git rev-parse HEAD)" > envs
rockcraft clean
rockcraft pack
```

Expected: `rockcraft pack` completes without errors. Output includes `docker-router-advertiser_1.0.0_amd64.rock` in the container directory.

- [ ] **Step 3: Verify the rock loads into Docker**

If using Option B above, also run the skopeo conversion:
```bash
sudo rockcraft.skopeo --insecure-policy copy oci-archive:docker-router-advertiser_1.0.0_amd64.rock docker-daemon:docker-router-advertiser:latest
docker load -i <(docker save docker-router-advertiser:latest)
```

Or if using Option A (build_rocks.sh), verify the output:
```bash
ls -la target/docker-router-advertiser.gz
docker load -i target/docker-router-advertiser.gz
```

Expected: `docker load` succeeds without errors.

- [ ] **Step 4: Investigate build errors if any**

If `rockcraft pack` fails, check (per meta-spec section 10.3):

| Error | Fix |
|-------|-----|
| Missing deb files | Ensure `target/debs/resolute/` contains socat, libswsscommon, libyang3, python3-libyang, python3-swsscommon, sonic-db-cli, sonic-eventd, libnl-*, sonic-supervisord-utilities-rs |
| Missing wheel files | Ensure `target/python-wheels/resolute/` contains sonic_py_common, sonic_yang_mgmt, sonic_yang_models, sonic_containercfgd, sonic_config_engine wheels |
| Package resolution errors | Check that `radvd` is available in ubuntu@26.04 (it should be — it's a standard Ubuntu package) |
| j2 rendering errors | Not applicable here — no build-time j2 rendering needed (templates are rendered at runtime by start.sh) |
| Missing shared libraries at load time | Check `docker load` output, add the missing library to `stage-packages` |

- [ ] **Step 5: Clean up build artifacts (if using Option B)**

If you used Option B (manual rockcraft pack), clean up the staged files:
```bash
cd dockers/docker-router-advertiser
rm -rf debs/ files/ python-wheels/ envs docker-router-advertiser_1.0.0_amd64.rock
```

These directories are gitignored and should not be committed.

- [ ] **Step 6: Final commit (if any fixes were needed during verification)**

If build errors required fixes to `rockcraft.yaml`, `start.sh`, or `build_rocks.sh`:

```bash
git add dockers/docker-router-advertiser/rockcraft.yaml dockers/docker-router-advertiser/start.sh build_rocks.sh
git commit -m "fix: address rockcraft build errors for docker-router-advertiser

<describe specific fixes applied>"
```

If no fixes were needed, no commit is required — Tasks 1-3 are already committed.

---

## Summary of Changes

| Task | File | Action | Lines Changed |
|------|------|--------|---------------|
| 1 | `dockers/docker-router-advertiser/rockcraft.yaml` | Create | ~110 lines (new file) |
| 2 | `dockers/docker-router-advertiser/start.sh` | Modify | +18 lines (append pebble branch) |
| 3 | `build_rocks.sh` | Modify | +1 line (append to rocklist) |
| 4 | — | Verify | No file changes |

**Total: 2 new/modified source files + 1 build script modification, ~130 lines of changes.**
