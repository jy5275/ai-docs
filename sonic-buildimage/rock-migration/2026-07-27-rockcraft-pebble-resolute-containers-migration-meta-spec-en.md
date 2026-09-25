# Rockcraft + Pebble Migration: Resolute Containers Meta-Spec

**Date:** 2026-07-27
**Branch:** `202605_resolute_rock`
**Scope:** All SONiC containers on `vs` and `broadcom` providing basic network functionality, excluding the four already migrated (docker-database, docker-sonic-mgmt-framework, docker-eventd, docker-router-advertiser).
**Reference:** `feature_noble_build` branch (Noble implementation, consulted but not copied); `dockers/docker-eventd` on Resolute (completed migration, the canonical pattern).

## 1. Goal

Migrate 18 containers from Dockerfile + supervisord to Rockcraft + Pebble on the
`202605_resolute_rock` branch (Ubuntu 26.04 / Resolute). Both the Dockerfile path and
the new Rockcraft path must coexist in the same branch for every container.

The results are pushed in this PR: https://github.com/canonical/sonic-buildimage/pull/9.
Before analysis and doing actual jobs, check if local repos and PR are in sync, and how many containers have already been migrated.

## 2. Container Inventory and Migration Order

Migration is done one container at a time, easy-to-hard. Each container gets its own
implementation plan (via the writing-plans skill) referencing this meta-spec for the
common pattern.

| Order | Container | Base image | Difficulty | Key challenge |
|-------|-----------|-----------|-----------|---------------|
| 1 | dockers/docker-mux | config-engine | ★ | single daemon (linkmgrd); create start.sh |
| 2 | dockers/docker-macsec | swss-layer | ★ | single daemon (macsecmgrd); wpa_supplicant.conf; create start.sh |
| 3 | dockers/docker-teamd | swss-layer | ★ | 3 daemons; iproute2 |
| 4 | dockers/docker-iccpd | swss-layer | ★ | iccpd.sh wrapper; sonic-cfggen renders iccpd.j2 |
| 5 | dockers/docker-sflow | swss-layer | ★ | 2 daemons; port_index_mapper.py; hsflowd sed |
| 6 | dockers/docker-sysmgr | config-engine | ★ | single daemon (rebootbackend); 202605 new, no Noble ref; D-Bus mount |
| 7 | dockers/docker-stp | config-engine | ★ | 2 daemons (stpd, stpmgrd); 202605 new, no Noble ref; start.sh uses supervisorctl |
| 8 | dockers/docker-nat | swss-layer | ★★ | 2 daemons + restore_nat_entries.py; iptables symlinks |
| 9 | dockers/docker-lldp | config-engine | ★★ | supervisord.conf.j2 (namespace_id); lldpmgrd 15KB Python; 4 daemons |
| 10 | dockers/docker-sonic-gnmi | config-engine | ★★ | gnmi-native.sh 150 lines; 2 daemons |
| 11 | dockers/docker-snmp | config-engine | ★★ | supervisord.conf.j2; snmpd.conf.j2 7KB; PYTHONOPTIMIZE=1; pip-compile hiredis |
| 12 | dockers/docker-dhcp-server | config-engine | ★★ | kea-dhcp4-server; supervisor group; 4 daemons + group dependency |
| 13 | dockers/docker-dhcp-relay | config-engine | ★★★ | **approach B**: per-VLAN dynamic relay agents; dynamic pebble layer |
| 14 | dockers/docker-orchagent | swss-layer | ★★★ | 356-line supervisord.conf.j2; docker-init.j2 rendered at build time; many .j2 templates |
| 15 | dockers/docker-platform-monitor | config-engine | ★★★★ | 314-line supervisord.conf.j2; 14+ conditional daemons; platform-specific logic; grpcio/thrift pip packages |
| 16 | dockers/docker-fpm-frr | swss-layer | ★★★★ | 279-line supervisord.conf.j2; FRR routing suite; 4 config modes; frr user/group |
| 17 | platform/broadcom/docker-syncd-brcm | — | ★★★★ | SAI syncd daemon; Broadcom platform-specific |
| 18 | platform/vs/docker-syncd-vs | — | ★★★★ | SAI syncd daemon; VS platform-specific |

**Already migrated** (out of scope): docker-database, docker-sonic-mgmt-framework,
docker-eventd, docker-router-advertiser.

**Note on 202605-new containers**: docker-sysmgr and docker-stp are new in the 202605
branch (no upstream Noble reference). They are simple config-engine based containers
and follow the standard pattern without special difficulty.

## 3. Architecture Overview

Each container's migration follows the docker-eventd Resolute pattern: flatten the
Docker three-layer inheritance chain (`docker-base-resolute` → `docker-config-engine-resolute`
/ `docker-swss-layer-resolute` → specific container) into a single `rockcraft.yaml`.

Key decisions (consistent with docker-eventd, applying to all 18 containers):

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Rockcraft base | `base: ubuntu@26.04` | Full Ubuntu runtime base; image size not a concern |
| build-base | `build-base: ubuntu@26.04` | Same as base |
| stage-packages | package names (not chisel slices) | docker-eventd precedent; docker-database uses slices but others use names |
| build-packages | build-only tools (python3-pip, git, gcc, make) | Build tools must not enter the runtime image |
| start.sh coexistence | `pgrep -x pebble` detection | Consistent with all migrated containers; both paths share same start.sh |
| supervisord in rock | Excluded | Rock path uses pebble; no supervisord packages, configs, or directories |
| Timezone commands in start.sh | Not included | Upstream removed these in 202405/202605 |
| deb filenames in rockcraft.yaml | Wildcards (`*_*.deb`) | Avoids hardcoding versions; resilient to dependency changes |
| Environment variables on services | None (no DEBIAN_FRONTEND/IMAGENAME/DISTRO) | docker-eventd precedent; these are build-time variables |

### 3.1 Why build-packages vs stage-packages

`build-packages` are installed in the build-base environment for the build step only and
do **not** enter the final rock. `stage-packages` are unpacked into the stage directory
and become part of the final rock's runtime. Build-only tools (compilers, `-dev` headers,
`python3-pip`, `git`) belong in `build-packages`; runtime dependencies belong in
`stage-packages`. This keeps the runtime image free of build tooling.

### 3.2 IMAGE_VERSION propagation through the envs file

The Dockerfile path bakes `IMAGE_VERSION` into the image via `ENV IMAGE_VERSION=$image_version`.
The rock path has no equivalent `ENV` step, so `IMAGE_VERSION` must cross the build boundary
through an `envs` file written by `build_rocks.sh` (which already emits it for every
container, then removes it during cleanup). The propagation chain has three links:

1. `build_rocks.sh` writes `echo "export IMAGE_VERSION=$(git rev-parse --abbrev-ref
   HEAD)-$(git rev-parse HEAD)" > $rockitem/envs` (already in place, no per-container change).
2. `rockcraft.yaml` copies it into the rock in `override-prime`:

   ```yaml
   override-prime: |
     craftctl default

     cp ${CRAFT_PROJECT_DIR}/files/rsyslog.conf etc/rsyslog.conf
     cp ${CRAFT_PROJECT_DIR}/manifest.json manifest.json
     cp ${CRAFT_PROJECT_DIR}/envs usr/share/sonic/templates/
   ```

3. `start.sh` sources it (guarded, so the docker/supervisord path stays clean):

   ```bash
   if [ -f /usr/share/sonic/templates/envs ]; then
       source /usr/share/sonic/templates/envs
   fi
   ```

**Scope it to actual consumers.** Only containers whose `start.sh` passes `IMAGE_VERSION`
to `container_startup.py` (`... -v ${IMAGE_VERSION}`) need any of the above. For those,
add **both** the `override-prime` copy and the `source`. Containers that never reference
`IMAGE_VERSION` (e.g. docker-eventd, docker-database, docker-sonic-mgmt-framework) must not
carry the `envs` copy — a copied-but-unsourced `envs` file is dead weight, and the
`build_rocks.sh` generator alone is not a reason to include it.

`DEBIAN_FRONTEND`/`IMAGENAME`/`DISTRO` are genuinely build-time and remain unset on services
(see the "Environment variables on services" decision above); this subsection concerns only
the runtime `IMAGE_VERSION`.

## 4. Shared Infrastructure (already in place)

Established by the docker-database / docker-eventd migrations. All 18 containers reuse
these without modification:

| File | Location | Purpose |
|------|----------|---------|
| `files/rsyslog/syslog-layer.yaml` | `rules/scripts.mk` → `RSYSLOG_PEBBLE_LAYER` | Pebble syslog layer; loaded by `pebble add syslog-layer --combine` in start.sh |
| `dockers/docker-base-resolute/etc/rsyslog.conf` | `rules/scripts.mk` → `RSYSLOG_CONF` | SONiC custom rsyslog config; copied in `override-prime` |
| `files/build_templates/rsyslog_plugin.conf.j2` | `rules/scripts.mk` → `RSYSLOG_PLUGIN_CONF_J2` | rsyslog plugin config template (eventd and similar) |
| `files/build_templates/docker_image_ctl.j2` | Already supports pebble + supervisord dual detection | Container start/stop script |
| `rules/scripts.mk` | `SONIC_COPY_FILES` includes all shared files | make stage copies them to `target/files/resolute/` |
| `build_rocks.sh` | Repo root | Rock build orchestration; each container appends one line to `rocklist` |

### 4.1 build_rocks.sh per-container change

The only change to `build_rocks.sh` per container is appending the container path to the
`rocklist` array:

```bash
rocklist=(
    "dockers/docker-database"
    "dockers/docker-sonic-mgmt-framework"
    "dockers/docker-eventd"
    "dockers/docker-router-advertiser"
    "dockers/docker-<name>"        # ← appended per container
)
```

The existing staging logic (copy `target/{debs,files,python-wheels}/resolute/*` into the
container dir, `rockcraft pack`, `rockcraft.skopeo` conversion, `docker save | pigz`)
requires no changes.

### 4.2 Build-integration steps (per container, mandatory)

Besides `rockcraft.yaml`, `start.sh` and the `build_rocks.sh` `rocklist` entry, every
migrated container needs the following build-system edits. They were learned from the first
four migrations and are NOT optional:

1. **`rules/docker-<name>.dep`** — exclude the rockcraft.yaml from the image dependency
   list so `make` never rebuilds the Dockerfile image over the rock:

   ```make
   DEP_FILES += $(filter-out $(DPATH)/rockcraft.yaml,$(shell git ls-files $(DPATH)))
   ```

   Without this, `make` treats `rockcraft.yaml` as an input of the Dockerfile-built image
   and overwrites the rock output with a supervisord image.

2. **`rules/docker-<name>.mk`** — only for containers currently installed as
   `SONIC_PACKAGES_LOCAL` (SPM) packages: **docker-dhcp-relay, docker-dhcp-server,
   docker-macsec**. Switch them to native docker images:

   ```make
   SONIC_INSTALL_DOCKER_IMAGES += $(DOCKER_<NAME>)
   ```

   A rock carries no `com.azure.sonic.versions.*` label, so installing it as an SPM package
   makes `sonic-package-manager install --from-tarball` fail its component-dependency
   validation (e.g. `dhcp-relay requires libswsscommon ^1.0.0 in package database^1.0.0 but
   it is not installed`).

3. **`stage-packages`** — if the rock `dpkg -x`'s `python3-libyang`, also stage
   `python3-cffi-backend` (which provides the `_cffi_backend` module); otherwise the daemons
   fail at runtime with `ImportError: _cffi_backend`.

## 5. Standard rockcraft.yaml Skeleton

All containers follow this three-part skeleton (based on docker-eventd). `<container-specific>`
placeholders are replaced per container.

```yaml
name: docker-<name>
summary: SONiC <name> container
description: A rock for SONiC <name> container
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
  <daemon-1>:
    command: <cmd>
    override: replace
    # No startup: key → default disabled, started by start.sh
  <daemon-2>:
    command: <cmd>
    override: replace

parts:
  setup-<name>:
    plugin: dump
    source: .
    build-packages:
      - python3-pip          # if override-build needs j2 or pip tools
    override-build: |
      craftctl default

      # 1. Install SONiC debs (wildcard filenames)
      dpkg -x debs/<pkg>_*.deb ${CRAFT_PART_INSTALL}
      ...

      # 2. Build-time j2 rendering (e.g. rsyslog_plugin.conf), if needed
      j2 -f json ...

      # 3. Clean up source files
      rm -rf ${CRAFT_PART_INSTALL}/debs ${CRAFT_PART_INSTALL}/python-wheels

    organize:
      start.sh: usr/bin/start.sh
      files/syslog-layer.yaml: usr/share/sonic/templates/syslog-layer.yaml
      files/swss_vars.j2: usr/share/sonic/templates/swss_vars.j2
      files/readiness_probe.sh: usr/bin/readiness_probe.sh
      files/container_startup.py: usr/share/sonic/scripts/container_startup.py
      <container-file>: <dest-path>

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
      - libdaemon0
      - libdbus-1-3
      - libjansson4
      - python3-redis
      - python3-yaml
      # SONiC deb runtime dependencies
      - libboost-serialization1.83.0
      - libhiredis1.1.0
      - libxxhash0
      # <container-specific packages>

    override-prime: |
      craftctl default

      cp ${CRAFT_PROJECT_DIR}/files/rsyslog.conf etc/rsyslog.conf
      cp ${CRAFT_PROJECT_DIR}/manifest.json manifest.json
      cp ${CRAFT_PROJECT_DIR}/envs usr/share/sonic/templates/  # only if start.sh sources it (§3.2)

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
      # <container-specific pip packages>
    stage-packages:
      - python3-venv

  add-user:
    plugin: nil
    after: [setup-<name>]
    overlay-script: |
      groupadd -R $CRAFT_OVERLAY syslog
      useradd -R $CRAFT_OVERLAY -M -r --system -g adm syslog
    prime:
      - etc/passwd
      - etc/group
```

### 5.1 Design notes for the skeleton

- **`organize` over `cp`**: Source file placement uses `organize` (declarative) rather
  than `cp` in `override-build`/`override-prime`. The only exceptions are `rsyslog.conf`
  (the `rsyslog` stage-package overwrites it with a default config, so it must be copied
  in `override-prime` after staging) and `manifest.json` (must be at the rock root).
- **deb wildcards**: `dpkg -x debs/<pkg>_*.deb` avoids hardcoding version numbers.
- **python symlink**: not needed. The `python3-minimal` apt package (pulled in by
  `stage-packages: [python3]`) already provides `/usr/bin/python3 -> python3.14`.
- **add-user part**: Creates the `syslog` user/group needed by rsyslog, using
  `overlay-script` in the overlay chroot where `/etc/passwd` and `/etc/group` come from
  the `ubuntu@26.04` base.
- **Noble reference deviation**: Noble's rockcraft.yaml files use many per-deb parts
  (`install-<deb>_<version>_amd64`) plus a large `install-common-files` part that copies
  everything via `cp` in `override-prime`. Resolute improves on this: a single
  `setup-<name>` part installs all debs via `dpkg -x` and places files via `organize`.
  This is more concise and more declarative.

### 5.2 Authoring principles

- **Keep it lean.** `rockcraft.yaml` should be as minimal as possible. The
  `feature_noble_build` branch's rockcraft.yaml files may contain redundant commands or
  entries carried over from earlier migrations. For every line in a `rockcraft.yaml`, be
  able to trace its necessity back to a concrete source in the current branch — typically
  `Dockerfile.j2`, `rules/*.mk`, or other files in the same container directory. If no
  such basis exists, the line is a candidate for removal.
- **Verify by removal, not by packing.** When an element is suspected to be unnecessary,
  remove it and test whether the rock still builds and runs. `rockcraft pack` runs the
  entire lifecycle (pull → overlay → build → stage → prime) plus OCI layer creation in one
  shot, which is slow for iterative testing. If the removed element only affects a specific
  lifecycle step, use the corresponding subcommand to inspect the intermediate state instead
  of packing the final artifact every time:

  | Command | Stops after | Inspect directory |
  |---------|-------------|-------------------|
  | `rockcraft build` | BUILD | `${CRAFT_PART_INSTALL}` |
  | `rockcraft stage` | STAGE | `${CRAFT_STAGE}` |
  | `rockcraft prime` | PRIME | `${CRAFT_PRIME}` |
  | `rockcraft prime --shell-after` | PRIME | drops into a shell in `${CRAFT_PRIME}` |

  This avoids waiting for the full `pack` cycle on every iteration. Reserve
  `rockcraft pack` (and the subsequent `docker load` / runtime check) for the final
  confirmation that the rock is correct and runnable.

- **Resolve stage-packages dependency closure, not the full list.** Rockcraft pulls
  `stage-packages` the way `apt-get install` does: it recursively resolves and installs
  every hard `Depends`/`PreDepends` of a listed package into the rock (you can see this in
  any `pack` log as a long tail of packages you never listed, e.g. `libc6`, `zlib1g`,
  `debconf`). So when package A hard-depends on B, listing only A is enough — B comes along
  automatically, and listing B too is dead weight. Before authoring the list, compute each
  package's dependencies on the same Ubuntu series as the rock base (for Resolute this is
  the build host's `ubuntu@26.04`) and drop any entry that is pulled in by a peer:

  ```bash
  apt-cache depends --no-suggests --no-recommends --no-breaks \
    --no-conflicts --no-replaces --no-enhances <pkg> | grep -E 'Depends|PreDepends'
  ```

  Two caveats temper this rule:

  1. **`dpkg -x` debs are invisible to the resolver.** The SONiC debs are unpacked with
     `dpkg -x` in `override-build`, not installed through apt, so their runtime `.so`
     dependencies are never resolved automatically. That is exactly why the skeleton's
     "SONiC deb runtime dependencies" group (e.g. `libboost-serialization1.83.0`,
     `libhiredis1.1.0`, `libxxhash0`) is listed explicitly: nobody else would pull them in.
     Do not dedupe this group against apt packages — only reason from what a listed
     *stage-package* already depends on.
  2. **Verify the base layer is not the provider.** A `.so` satisfied by `ubuntu@26.04`
     itself is dead weight too, but that is a different check (see §9.10's libpam note) and
     orthogonal to the dependency-closure rule here.

  Concrete instance: the skeleton once carried `libatomic1` (a hard dependency of
  `redis-tools`) and `libuuid1` (a hard dependency of `rsyslog`). Both are redundant
  because every rock stages `redis-tools` and `rsyslog`; they were removed from §5 and the
  migrated containers, leaving only the non-resolved entries behind.

## 6. start.sh Universal Pattern

Every container's `start.sh` follows this structure:

```bash
#!/usr/bin/env bash

# <container's existing init logic preserved verbatim>

if [ -f /usr/share/sonic/templates/envs ]; then   # only if start.sh consumes IMAGE_VERSION (§3.2)
    source /usr/share/sonic/templates/envs
fi

if pgrep -x pebble > /dev/null 2>&1; then
    LAYER_FILE="/usr/share/sonic/templates/syslog-layer.yaml"
    pebble add syslog-layer --combine $LAYER_FILE
    pebble replan
    pebble start <daemon-1>
    pebble start <daemon-2>
fi
```

- **Docker path (supervisord)**: `pgrep -x pebble` returns false. Only the existing init
  logic runs; daemons are started by supervisord's `dependent_startup_wait_for`. The
  guarded `source` of `envs` is inert because the file is absent from the Docker image.
- **Rock path (pebble)**: `pgrep -x pebble` returns true. Loads syslog layer, replans,
  then explicitly starts daemons via `pebble start`.
- **No timezone commands**: upstream removed these in 202405/202605.
- **No environment variables on pebble services**: consistent with docker-eventd.

## 7. Conditional Daemon Handling: Approach A and B

### 7.1 Approach A — static services + start.sh on-demand start (default)

**Applies to**: all containers except docker-dhcp-relay.

The `services` section in `rockcraft.yaml` enumerates every daemon the container **may**
run. All daemons except `rsyslogd` and `start` omit the `startup` key (default `disabled`,
no auto-start). `start.sh`'s pebble branch reads runtime configuration (via `sonic-cfggen`
or `sonic-db-cli`) and starts the appropriate daemons with `pebble start <name>`.

The `start` service has `on-success: ignore` so it doesn't restart after exiting.
Daemon startup order is controlled entirely by the sequence of `pebble start <name>`
calls in start.sh — no `after:` keys are used, because `pebble start` is an explicit
one-shot action that does not consult `after:` dependencies.

**Example (docker-lldp)**:

```yaml
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
  lldpd:
    command: /usr/sbin/lldpd -t -f /etc/lldpd.conf
    override: replace
  waitfor-lldp-ready:
    command: /usr/bin/waitfor_lldp_ready.sh
    override: replace
    on-success: ignore
    on-failure: ignore
  lldp-syncd:
    command: python3 -m lldp_syncd
    override: replace
  lldpmgrd:
    command: /usr/bin/lldpmgrd
    override: replace
```

```bash
# start.sh pebble branch
if pgrep -x pebble > /dev/null 2>&1; then
    LAYER_FILE="/usr/share/sonic/templates/syslog-layer.yaml"
    pebble add syslog-layer --combine $LAYER_FILE
    pebble replan

    sonic-cfggen -d -a '{"namespace_id":"$NAMESPACE_ID"}' -t lldpd.conf.j2 -y sonic_version.yml -t lldpdSysDescr.conf.j2 > /etc/lldpd.conf
    rm -f /var/run/lldpd.socket

    pebble start lldpd
    pebble start waitfor-lldp-ready
    pebble start lldp-syncd
    pebble start lldpmgrd
fi
```

### 7.2 Approach B — dynamic pebble layer (docker-dhcp-relay only)

**Applies to**: docker-dhcp-relay (per-VLAN relay agents, count determined at runtime,
cannot be enumerated statically).

The `services` section declares only static services (`rsyslogd`, `start`, `dhcprelayd`).
A new file `pebble-layer.j2` translates the original `supervisord.conf.j2` into pebble
layer YAML format. `start.sh` renders it at startup via `sonic-cfggen -d -t pebble-layer.j2`
and injects it with `pebble add dhcp-relay-layer --combine`.

```yaml
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
  dhcprelayd:
    command: /usr/local/bin/dhcprelayd
    override: replace
```

```bash
# start.sh pebble branch
if pgrep -x pebble > /dev/null 2>&1; then
    LAYER_FILE="/usr/share/sonic/templates/syslog-layer.yaml"
    pebble add syslog-layer --combine $LAYER_FILE
    pebble replan

    sonic-cfggen -d -t /usr/share/sonic/templates/pebble-layer.j2 > /tmp/dhcp-relay-layer.yaml
    pebble add dhcp-relay-layer --combine /tmp/dhcp-relay-layer.yaml
    pebble replan

    pebble start dhcprelayd
fi
```

**supervisord → pebble mapping** (used when writing `pebble-layer.j2`):

| supervisord | pebble |
|-------------|--------|
| `[program:name]` | `name:` |
| `command=...` | `command: ...` |
| `autostart=false` | (omit `startup`, default disabled) |
| `dependent_startup_wait_for=X:running` | (no pebble equivalent; order controlled by start.sh's `pebble start` call sequence) |
| `stopsignal=KILL` | `kill-delay: 0s` |
| `priority=N` | (no pebble equivalent; order controlled by start.sh) |

### 7.3 Fallback

If docker-platform-monitor or docker-fpm-frr prove too complex for approach A during
implementation (e.g., the start.sh conditional logic becomes unwieldy), they can fall
back to approach B by writing a `pebble-layer.j2` following the dhcp-relay pattern. This
fallback is reserved in the design but not the default.

## 8. Comparison Baseline

The remote switch `et3-dh3-f-sw1` may currently be running Ubuntu Resolute SONiC. If so, it
serves as a useful comparison baseline: every container on that machine is still built from a
Dockerfile, with services managed by supervisord. The objective is for each migrated
Rockcraft + Pebble container `docker-<name>` to replicate the behavior of its counterpart on
that machine and expose the same set of services.

Before authoring the `stage-packages` list in `rockcraft.yaml`, inspect the packages actually
installed in the corresponding container on `et3-dh3-f-sw1` to ensure the rock's runtime
environment matches.

The remote switch `et3-dh3-f-sw1` must be accessed throught company VPN. A connection
timeout may suggest company VPN has been turned on. If you're unable to turn it on 
yourself, stop and ask me to turn it on manually.


## 9. Per-Container Migration Notes

This section gives each container's key deviations from the standard skeleton. The four
already-migrated containers are excluded.

### 9.1 docker-mux (config-engine base)

- Single daemon linkmgrd. Noble used a rock-init.sh + `/tmp/init_ok` file-signal pattern;
  Resolute simplifies to the standard start.sh pattern.
- **services**: rsyslogd, start, linkmgrd.
- **No existing start.sh** — must **create** start.sh with pebble branch
  (`pebble start linkmgrd`).
- **linkmgrd command**: `nice -n -20 /usr/sbin/linkmgrd -v warning -d -l`.
- **stage-packages +=**: libboost-thread/log/program-options/filesystem1.83.0,
  libevent-2.1-7, libxml2.

### 9.2 docker-macsec (swss-layer base)

- Single daemon macsecmgrd.
- **services**: rsyslogd, start, macsecmgrd.
- **No existing start.sh** — must **create** start.sh.
- **organize +=**: `etc/wpa_supplicant.conf: etc/wpa_supplicant.conf`, `cli/: cli/`.
- **stage-packages +=**: swss-layer inherited (libteam5, libteamdctl0, libsairedis,
  libsaimetadata, swss debs) + macsec-specific (wpasupplicant deb, libpcsclite1,
  liblua5.1-0).
- **rules docker-macsec.mk**: switch `SONIC_PACKAGES_LOCAL` → `SONIC_INSTALL_DOCKER_IMAGES`
  (see §4.2).

### 9.3 docker-teamd (swss-layer base)

- 3 daemons: teammgrd, teamsyncd, tlm_teamd.
- **services**: rsyslogd, start, teammgrd, teamsyncd, tlm_teamd.
- **start.sh**: existing (`rm -f /var/run/teamd/*; mkdir -p /var/warmboot/teamd`), append
  pebble branch.
- **stage-packages +=**: iproute2 (teammgrd needs `ip` binary) + swss-layer inherited.
- **special**: teammgrd `stopwaitsecs=60` → `kill-delay: 60s`; teamsyncd `startsecs=5` →
  start.sh calls `pebble start teamsyncd` after teammgrd.

### 9.4 docker-iccpd (swss-layer base)

- 1 daemon iccpd (via iccpd.sh wrapper starting mclagsyncd + iccpd as background).
- **services**: rsyslogd, start, iccpd.
- **start.sh**: existing (`sonic-cfggen -d -t iccpd.j2 > /etc/iccpd/iccpd.conf`), append
  pebble branch.
- **iccpd.sh**: wrapper script, runs mclagsyncd + iccpd in background, blocks on `read`.
  Used directly as pebble service command.
- **organize +=**: iccpd.sh, iccpd.j2 → templates.
- **stage-packages +=**: iptables, ebtables.
- **No critical_processes file** (unique among surveyed containers).

### 9.5 docker-sflow (swss-layer base)

- 2 daemons: sflowmgrd, port_index_mapper.
- **services**: rsyslogd, start, sflowmgrd, port_index_mapper.
- **No existing start.sh** — must **create** start.sh.
- **organize +=**: port_index_mapper.py.
- **stage-packages +=**: dmidecode.
- **special**: Dockerfile does `sed -ri '/^DAEMON_ARGS=""/c ...' /etc/init.d/hsflowd` —
  place this sed in `override-build` operating on `${CRAFT_PART_INSTALL}`.

### 9.6 docker-sysmgr (config-engine base)

- Single daemon: rebootbackend. 202605-new container, no Noble reference.
- **services**: rsyslogd, start, rebootbackend.
- **No existing start.sh** — must **create** start.sh (pebble branch: `pebble start
  rebootbackend`).
- **sysmgr.sh**: wrapper script (`exec /usr/local/bin/sysmgr --logtostderr`). Not a
  supervisord program — install via organize, the `rebootbackend` service runs
  `/usr/bin/rebootbackend` directly.
- **organize +=**: sysmgr.sh → `usr/bin/` (if needed at runtime).
- **stage-packages +=**: libdbus-1-3, libdbus-c++-1-0v5.
- **special**: mounts `/var/run/dbus` (D-Bus system bus). Docker path RUN_OPT includes
  `-v /var/run/dbus:/var/run/dbus:rw`; the rock's `docker run` command must replicate
  this mount for the container to function.

### 9.7 docker-stp (config-engine base)

- 2 daemons: stpd, stpmgrd. 202605-new container, no Noble reference.
- **services**: rsyslogd, start, stpd, stpmgrd.
- **start.sh**: existing (`rm -f /var/run/rsyslogd.pid; rm -f /var/run/stpd/*; rm -f
  /var/run/stpmgrd/*; supervisorctl start rsyslogd; supervisorctl start stpd;
  supervisorctl start stpmgrd`). The `supervisorctl` calls must be replaced by pebble
  equivalents in the pebble branch: `pebble start stpd; pebble start stpmgrd`. rsyslogd
  is auto-started (`startup: enabled`), no need to start it explicitly.
- **organize +=**: start.sh (already in standard skeleton).
- **stage-packages +=**: libdaemon0, libjansson4, libjemalloc2, ebtables.
- **special**: Dockerfile installs `libpython3.11` — on Resolute this should be
  `libpython3.14` (or omitted if already pulled in by `python3` stage-package).

### 9.8 docker-nat (swss-layer base)

- 3 daemons: natmgrd, natsyncd, restore_nat_entries.
- **services**: rsyslogd, start, natmgrd, natsyncd, restore_nat_entries.
- **start.sh**: existing (`rm -f /var/run/nat/*; mkdir -p /var/warmboot/nat`), append
  pebble branch.
- **organize +=**: restore_nat_entries.py.
- **stage-packages +=**: bridge-utils, conntrack, iptables.
- **special**: iptables symlinks (iptables→iptables-nft etc.) in `override-prime` via
  `ln -s` (organize cannot create symlinks).

### 9.9 docker-lldp (config-engine base)

- 4 daemons: lldpd, waitfor-lldp-ready, lldp-syncd, lldpmgrd.
- supervisord.conf.j2 rendered at startup (namespace_id). Approach A.
- **services**: rsyslogd, start, lldpd, waitfor-lldp-ready, lldp-syncd, lldpmgrd.
- **start.sh**: existing (renders lldpd.conf, lldpdSysDescr.conf, clears socket), append
  pebble branch starting all four daemons in order.
- **organize +=**: lldpmgrd (15KB Python script), lldpd (default config → etc/default/),
  waitfor_lldp_ready.sh, *.j2 templates.
- **python-packages +=**: lldp_syncd wheel (if in docker_lldp_whls).

### 9.10 docker-sonic-gnmi (config-engine base)

- 2 daemons: gnmi-native, dialout.
- **services**: rsyslogd, start, gnmi-native, dialout.
- **start.sh**: existing (container_startup.py + config_status), append pebble branch
  (`pebble start gnmi-native; pebble start dialout`).
- **organize +=**: gnmi-native.sh, dialout.sh, telemetry_vars.j2.
- **stage-packages +=**: none beyond the standard config-engine list.

The two container-specific deb entries are the only additions to the standard
`setup-<name>` deb list, on top of the config-engine-inherited set (socat,
libnl family, libswsscommon, libyang3, python3-libyang, python3-swsscommon,
sonic-db-cli, sonic-eventd):

- `sonic-mgmt-common`: ships `/usr/sbin/schema/` (the CVL schema) and
  `/usr/sbin/cvl_cfg.json`, required by `CVL_SCHEMA_PATH=/usr/sbin/schema`
  in gnmi-native.sh and dialout.sh.
- `sonic-gnmi`: ships the `telemetry` and `dialout_client_cli` binaries and the
  `/usr/models/yang/` YANG bundles dialout loads at startup.

`libxml2` and `libevent-2.1-7` (listed in earlier drafts of this section) are
**not** required: `objdump -p` on the `telemetry` and `dialout_client_cli`
binaries shows no libxml2/libevent NEEDED entries. The binary's real runtime
link set is libswsscommon, libhiredis, libpython3.14, libpam, libyang, libstdc++,
libgcc_s, libc.

`libpam.so.0` is supplied by the `ubuntu@26.04` base layer (verified as present
in the base OCI blob), so it must **not** be added as a stage-package: rockcraft
dedupes the staged copy against the base and drops it during PRIME, making the
entry dead weight. The same dedup argument applies in general — confirm a
library is actually absent from `ubuntu@26.04` before adding it to
`stage-packages`.

### 9.11 docker-snmp (config-engine base)

- 2 daemons: snmpd, snmp-subagent.
- supervisord.conf.j2 rendered at startup. Approach A.
- **services**: rsyslogd, start, snmpd, snmp-subagent.
- **start.sh**: existing (snmp_yml_to_configdb.py + sonic-cfggen renders snmpd.conf),
  append pebble branch.
- **organize +=**: snmp_yml_to_configdb.py, *.j2 templates.
- **stage-packages +=**: snmp, snmpd, ipmitool.
- **python-packages +=**: hiredis, pyyaml, smbus.
- **special**: `PYTHONOPTIMIZE=1` → rockcraft.yaml top-level `environment:`. Build-time
  `python3 -m sonic_ax_impl install` → `override-build`. pip-compile hiredis needs
  python3-dev, gcc, make → these go in **build-packages** (not stage-packages).

### 9.12 docker-dhcp-server (config-engine base)

- 2 daemons + supervisor group: dhcpservd, kea-dhcp4. Original used group
  `dhcp-server-ipv4`.
- **services**: rsyslogd, start, dhcpservd, dhcpservd-ready (wait_for_dhcpservd.sh),
  kea-dhcp4. Pebble has no group concept; startup order is controlled by start.sh's
  `pebble start` call sequence: dhcpservd → dhcpservd-ready → kea-dhcp4.
- **start.sh**: existing (container_startup.py), append pebble branch.
- **docker_init.sh**: creates kea dirs, chmod, gets udp_server_ip. Rock path: dir creation
  moves to `override-prime` or start.sh.
- **organize +=**: kea-dhcp4.conf.j2, kea-dhcp4-init.conf, lease_update.sh,
  wait_for_dhcpservd.sh, docker_init.sh (merge logic into start.sh if needed).
- **stage-packages +=**: kea-dhcp4-server, tcpdump.
- **python-packages +=**: psutil.
- **special**: psutil compilation needs python3-dev, build-essential → these go in the
  install-python part's **build-packages**.
- **rules docker-dhcp-server.mk**: switch `SONIC_PACKAGES_LOCAL` → `SONIC_INSTALL_DOCKER_IMAGES`
  (see §4.2).

### 9.13 docker-dhcp-relay (config-engine base) — approach B

- Per-VLAN dynamic relay agents. **The only approach B container.**
- **services**: rsyslogd, start, dhcprelayd (static only; per-VLAN agents via dynamic
  pebble layer).
- **New file**: `pebble-layer.j2` (translates supervisord.conf.j2 to pebble layer YAML).
- **start.sh**: existing, append pebble branch that renders `pebble-layer.j2` and
  `pebble add` it.
- **organize +=**: all .j2 templates → templates, start.sh.
- **python-packages +=**: psutil, sonic_dhcp_utilities wheel.
- **special**: docker_init.sh rendered supervisord.conf.j2 at startup; Rock path
  replaces this with pebble-layer.j2 rendering in start.sh.
- **rules docker-dhcp-relay.mk**: switch `SONIC_PACKAGES_LOCAL` → `SONIC_INSTALL_DOCKER_IMAGES`
  (see §4.2).

### 9.14 docker-orchagent (swss-layer base)

- Many daemons: orchagent, portsyncd, neighsyncd, vlanmgrd, intfmgrd, portmgrd, vrfmgrd,
  buffermgrd, countercheck, tunnel_packet_handler, etc. (356-line supervisord.conf.j2).
- Approach A: enumerate all, start.sh starts on-demand.
- **docker-init.j2 rendered at build time** (`sonic-cfggen -a '{"CONFIGURED_PLATFORM":"..."}'`)
  — Rock path: reproduce this rendering in `override-build` (or keep the rendered script).
- **organize +=**: many .j2 templates, *.sh scripts, *.py scripts, *.conf.
- **stage-packages +=**: swss-layer inherited + orchagent-specific.
- **special**: tunnel_packet_handler.py (14KB), enable_counters.py, buffermgrd.sh,
  orchagent.sh (149 lines), swssconfig.sh.

### 9.15 docker-platform-monitor (config-engine base)

- 14+ conditional daemons: bmcctld, chassisd, chassis_db_init, lm-sensors, fancontrol,
  ledd, xcvrd, ycabled, psud, syseepromd, thermalctld, pcied, sensormond, stormond,
  delay.
- Approach A: enumerate all in services, start.sh conditionally starts.
- **docker-pmon.supervisord.conf.j2** (314 lines) rendered at startup — no longer needed
  for pebble path (services declared in rockcraft.yaml). But `docker_init.j2` platform
  detection (mellanox/aspeed/bluefield, sonic_platform wheel install) must be preserved
  in start.sh.
- **organize +=**: delay.py, lm-sensors.sh, ssd_tools/*, etc/rsyslog.conf,
  docker-pmon.supervisord.conf.j2 (keep for reference, rock path doesn't use).
- **stage-packages +=**: ipmitool, librrd8t64, rrdtool, python3-smbus, dmidecode,
  i2c-tools, psmisc, python3-netifaces, libpci3, iputils-ping, pciutils, nvme-cli,
  ethtool, xxd, python3-bottle, smartmontools.
- **python-packages +=**: grpcio==1.71.0, grpcio-tools==1.71.0, thrift==0.13.0, requests,
  python-dateutil==2.9.0.post0, libpci, psutil, blkinfo, smbus2.
- **special**: grpc `.so` strip (in `override-build`); ssd_tools/SmartCmd 2.4MB binary;
  docker_init.j2 rendered at build time (in `override-build`).

### 9.16 docker-fpm-frr (swss-layer base)

- FRR routing suite: zebra, bgpd, staticd, mgmtd, bfdd, ospfd, pimd, pathd, sharpd,
  fpmsyncd, bgpcfgd/frrcfgd, bgpmon, bfdmon, vtysh_b, bgp_eoiu_marker, zsocket, etc.
- Approach A: enumerate all in services, start.sh conditionally starts.
- **docker_init.sh** (130 lines) renders supervisord.conf.j2, critical_processes.j2,
  isolate.j2, unisolate.j2, handles 4 routing config modes (separated/split/
  split-unified/unified), modifies default gateway, creates sr0 dummy interface. Rock
  path: most of this moves to start.sh's pebble branch.
- **frr user/group**: create via `add-user` part's `overlay-script` with specified
  UID/GID (frr_user_uid, frr_user_gid).
- **organize +=**: entire frr/ template tree, docker_init.sh, snmp.conf, TS*, zsocket.sh.
- **stage-packages +=**: logrotate, libgoogle-perftools4t64 (conditional).
- **special**: 4 config modes, Traffic Shift scripts (TS/TSA/TSB/TSC), sr0 dummy interface.

### 9.17 platform/broadcom/docker-syncd-brcm

- Core daemon: syncd (SAI implementation, Broadcom SDK).
- **services**: rsyslogd, start, syncd.
- **organize**: Broadcom platform-specific config, SAI libraries.
- **stage-packages**: Broadcom SDK runtime libraries.
- **special**: requires investigation of `platform/broadcom/docker-syncd-brcm/Dockerfile.j2`
  and `.mk` before implementation (not fully surveyed in this design).

### 9.18 platform/vs/docker-syncd-vs

- Core daemon: syncd (VS SAI implementation).
- **services**: rsyslogd, start, syncd.
- **special**: requires investigation of `platform/vs/docker-syncd-vs/` before
  implementation. Noble's `build_rocks.sh` had it commented out, so no direct reference.

## 10. Files to Create / Modify (per container)

Each container migration touches:

### 10.1 New files

| File | Description |
|------|-------------|
| `<container>/rockcraft.yaml` | Rockcraft manifest (from section 5 skeleton) |
| `<container>/pebble-layer.j2` | **Only docker-dhcp-relay**: dynamic pebble layer template |
| `<container>/start.sh` | **Only containers without one**: docker-mux, docker-macsec, docker-sflow (create with pebble branch) |

### 10.2 Modified files

| File | Change |
|------|--------|
| `<container>/start.sh` | Append pebble detection and orchestration block (for containers with existing start.sh) |
| `build_rocks.sh` | Append `"<container>"` to rocklist |
| `rules/docker-<name>.dep` | `filter-out` the rockcraft.yaml from the dependency list (see §4.2) |
| `rules/docker-<name>.mk` | Only for docker-dhcp-relay/dhcp-server/macsec: switch `SONIC_PACKAGES_LOCAL` → `SONIC_INSTALL_DOCKER_IMAGES` (see §4.2) |

### 10.3 Unmodified files

| File | Reason |
|------|--------|
| `Dockerfile.j2` | Docker path unchanged (coexistence) |
| `supervisord.conf` / `supervisord.conf.j2` | Docker path only; not used in rock |
| `critical_processes` | Docker path only; not used in rock |
| `rules/<container>.mk` | Unchanged, except docker-dhcp-relay/dhcp-server/macsec (see §4.2) |
| `rules/scripts.mk` | Already updated by docker-database migration |
| `files/build_templates/docker_image_ctl.j2` | Already supports pebble detection |

## 11. Verification (per container)

Many containers depend on the SONiC runtime environment and configuration files (Config
DB, platform config, shared state) that are not present on a bare machine. Verification at
this stage covers three layers: (1) Docker path regression, (2) successful rockcraft packing
and image loading, (3) a limited runtime check by starting the container directly on the
build machine, and (4) pack rock into SONiC vs image. Full runtime verification (daemon
functionality under a complete SONiC image) is deferred.

### 11.1 Docker path regression

This step is to ensure that all `docker-<name>`'s dependencies has been built.
If `target/docker-<name>.gz` file already exists, this may indicate that all dependencies are ready,
we can skip this step. Unless step 11.2 reports error.
```bash
make target/docker-<name>.gz
```

The pebble detection in `start.sh` does not affect the Docker path because
`pgrep -x pebble` returns false in a supervisord container.

### 11.2 Rock build and load

```bash
# Prerequisite: make has been run to populate target/
./build_rocks.sh
```

Verify:
- `target/docker-<name>.gz` is generated (rockcraft pack completes without errors)
- `docker load -i target/docker-<name>.gz` succeeds (image loads into Docker daemon)

### 11.3 Rock build error investigation

If `rockcraft pack` fails, check:
- Missing deb files: ensure `target/debs/resolute/` contains the expected SONiC debs
- Missing wheel files: ensure `target/python-wheels/resolute/` contains the expected wheels
- Package resolution errors: stage-packages or build-packages not available in ubuntu@26.04
- j2 rendering errors: `j2` tool available (from jinjanator) and template/data files staged
- Missing shared libraries at load time: check `docker load` output and add the missing
  library to `stage-packages`

### 11.4 Limited runtime verification (bare machine)

After the rock builds and loads successfully, perform a limited runtime check by starting the container directly on any Ubuntu machine:
```bash
# For .rock file
sudo rockcraft.skopeo --insecure-policy \
    copy oci-archive:docker-${NAME}_1.0.0_amd64.rock \
    docker-daemon:docker-${NAME}:latest

# For .gz file
docker load -i target/docker-${NAME}.gz

docker container stop ${NAME}_rock || true
docker container rm ${NAME}_rock || true

docker run -d --name ${NAME}_rock -t --security-opt apparmor=unconfined --security-opt="systempaths=unconfined" docker-${NAME}:latest
```

Then check:

1. **Container does not crash immediately**: `docker ps` shows the container still running
   after a few seconds (not exited).
2. **Pebble services status**: `docker exec <name>_rock pebble services` shows services
   with expected states (e.g. `rsyslogd` active, `start` inactive/exited with ignore).
3. **Pebble logs for errors**: `docker exec <name>_rock pebble logs` and
   `docker exec <name>_rock pebble logs <service>` — look for ImportError, missing shared
   library, or crash messages.

As noted above, many containers depend on the SONiC runtime environment and configuration
files (Config DB, platform config, shared state) that are not present on a bare machine.
Therefore, errors observed in this step do **not** necessarily require fixing the source
code — they may simply be missing runtime dependencies. However, if an error is
obviously caused by a source code issue (as opposed to a missing runtime environment),
it should be fixed. For example, if `pebble logs <service>` shows a Python traceback or a
missing binary that should have been packaged into the rock, that is a build/packaging
defect to fix.

### 11.5 Pack rock into SONiC vs image
This step should be done after 11.2. Now the `target/docker-<name>.gz` is already a 
rockcraft packed container image.

```bash
stat target/docker-<name>.gz # Record the birth time here. 
rm -f target/sonic-vs.img.gz
make target/sonic-vs.img.gz
stat target/docker-<name>.gz # Verify the birth time doesn't change - the gz file shouldn't have been overwritten by the last make command.
```

### 11.6 Full runtime verification

This is a manual, end-to-end verification of migrated containers running under a complete
SONiC VS image. It covers: access, container-inventory sanity, a per-container checklist,
regression of the un-migrated Docker path, and a scripted pass/fail harness. It is the
gate before a migration is considered done at the image level.

#### 11.6.1 Launch the image and log in

Build the full image first (see §11.5), then launch the QEMU VM daemonized, poll for SSH,
and run commands on the switch — all in the same shell. `hostfwd` forwards guest port 22 to
host `127.0.0.1:2200`; `-display none -serial file:...` detaches the serial console (so it
does not hold the terminal) while still capturing SONiC boot output for debugging. log in
over SSH (default credentials `admin` / `YourPaSsWoRd`):

```bash
gunzip -kc target/sonic-vs.img.gz > target/sonic-vs.img

sudo qemu-system-x86_64 -m 8192 -smp 4 -boot order=c -name sonic \
      -drive file=target/sonic-vs.img,media=disk,if=virtio \
      -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2200-:22 -device virtio-net-pci,netdev=net0 \
      -display none -daemonize -pidfile /tmp/sonic-vs.pid \
      -serial file:/tmp/sonic-vs-serial.log

# Remove fingerprint string (ignore if not exist)
ssh-keygen -f '/home/ubuntu/.ssh/known_hosts' -R '[127.0.0.1]:2200'

# wait until sshd is reachable, then use the same session
until sshpass -p 'YourPaSsWoRd' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -p 2200 admin@127.0.0.1 'true' </dev/null 2>/dev/null; do
    sleep 10
done
echo "switch up"

sshpass -p 'YourPaSsWoRd' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p 2200 admin@127.0.0.1 \
    'uname -r'   # 7.0.0-1002-sonic
```

To observe the serial console (e.g. boot failures/panics) without a second interactive
session: `tail -f /tmp/sonic-vs-serial.log`. Stop the VM with
`sudo kill "$(cat /tmp/sonic-vs.pid)"`.

> All verification commands below are issued on the **switch** (via `sshpass ... ssh ...
> admin@127.0.0.1 '<cmd>'`), not on the build host. Allow a few minutes after boot for all
> containers to start before judging results; `syncd`/`swss` initialisation can take a while.

#### 11.6.2 Container inventory sanity

Some containers may be disabled by default, enable them in order to observe and test:
```bash
show feature status
sudo config feature state macsec enabled
sudo config feature state iccpd enabled
sudo config feature state nat enabled
sudo config feature state sflow enabled
...
```

Confirm the expected set of containers is up, then classifies each as rock (pebble) or
Docker (supervisord). The reliable discriminator is the presence of `com.azure.sonic.versions.*`
labels, which the Docker path bakes into the image and the rock path omits entirely (§4.2):

```bash
# 1. All containers and their state
docker ps --format '{{.Names}}\t{{.Status}}'

# 2. Classify each: 0 = rock, >=1 = Docker-path
for c in $(docker ps --format '{{.Names}}'); do
  n=$(docker inspect "$c" --format '{{range $k,$v := .Config.Labels}}{{$k}} {{end}}' \
        | grep -c 'com.azure.sonic.versions' || true)
  echo "$c  azure-labels=$n"
done
```

Interpretation:

| azure-labels | path | expected init (`docker exec <c> ps -p 1 -o comm=`) |
|--------------|------|---------------------------------------------------|
| `0` | rock | `pebble` |
| `>=1` | Docker | `supervisord` |

Note `docker exec <c> ps -p 1 -o comm=` is unreliable for containers launched with
`--pid host` (e.g. `docker-sonic-gnmi` runs with the host PID namespace, so PID 1 inside the
container is the host's `systemd`, and `pgrep -x pebble` matches *all* pebbles host-wide).
For those containers rely on `pebble services` and `pebble logs` only.

Minor gotchas: the `database` rock has no `sh` in `$PATH` (its entrypoint is
`/usr/bin/pebble enter` and only `bash` is present), so use `docker exec database pebble …`
or `docker exec database bash -c '…'`, never `docker exec database sh -c '…'`. Other rocks
ship `sh` and accept `docker exec <c> sh -c '…'`.

| Container | In rocklist? | Discriminator check |
|-----------|--------------|---------------------|
| database, mgmt-framework, eventd, radv (router-advertiser), lldp, snmp, gnmi | yes | `azure-labels=0`, `pebble services` returns a non-empty plan |
| swss, pmon, syncd, teamd, bgp, mux, iccpd, nat, … | no | `azure-labels>=1`, `docker exec <c> supervisorctl status` works |

As each of the 18 migrations lands, its container moves from the bottom row to the top.

#### 11.6.3 Expected pebble service state (per migrated container)

Every rock exposes the same skeleton plus its container-specific daemons. `rsyslogd` is
`startup: enabled` and `active`; `start` is `startup: enabled` but `inactive` after its
initial run.
Daemon services have `startup: disabled` in the plan — whether they end up `active` is
decided by `start.sh` reading runtime config. Run and compare:

```bash
docker exec <container> pebble services
```

If any service is in `backoff` or `error` state, that should be an error.

Each service's state should match the respecitve service's state on respecitve container on
`et3-dh3-f-sw1` remote switch. For example, if `docker exec database supervisorctl status redis` 
on `et3-dh3-f-sw1` is active/inactive, then `docker exec database pebble services redis` 
on our VM must show similar state (although pebble and supervisord may use different terminologies).


#### 11.6.4 Log checks (per migrated container)

For each rock container, run the two checks 

1. Pebble doesn't have error operations

   ```bash
   docker exec <c> pebble changes           # every Spawned start change must be status Done, no Error
   docker exec <c> pebble checks            # health-check config sanity (no checks in this skeleton)
   docker exec <c> pebble health            # overall: healthy
   ```

2. Logs — no `ImportError`, `Traceback`, `cannot open shared object file`, `undefined
   symbol`, or crash loop:

   ```bash
   docker exec <c> pebble logs            # all buffered service logs (30 lines default)
   docker exec <c> pebble logs <service>  # one service; add -n=all for the complete buffer
   ```

   Fall back to `docker logs` for the same stream if `pebble logs` shows nothing. Filtering
   advice: only `ImportError`, `Traceback`, `cannot open shared object file`,
   `undefined symbol`, and `panic:` are real defect markers. Do **not** flag as defects the
   benign noise seen routinely on a healthy VS image:

   - `rsyslogd: omrelp ... error opening connection to remote peer` — expected when no
     central syslog server is reachable;
   - `... 'events' list is missing or empty. Skipping ...` (eventd eventdb) — normal.


#### 11.6.5 Scripted pass/fail harness

Run once per image to get one-line signal per container. Adapt the two `case` arms to the
currently migrated set:

```bash
#!/usr/bin/env bash
# Verify rock/pebble containers under a booted SONiC vs image.  Args: none.
set -u
ROCKS=(database mgmt-framework eventd radv lldp snmp gnmi)   # update as migrations land
# Real defect markers only (see §11.6.4 for the benign-noise exclusion list).
DEFECTS='ImportError|Traceback|cannot open shared object file|undefined symbol|panic:'
for c in "${ROCKS[@]}"; do
  if docker exec "$c" pebble services >/dev/null 2>&1; then
    if docker exec "$c" pebble logs -n=all 2>&1 | grep -Eq "$DEFECTS"; then
      echo "$c: rock RUNNING, logs=DEFECT (inspect: docker exec $c pebble logs -n=all)"
    else
      echo "$c: rock RUNNING, logs=clean"
    fi
  else
    echo "$c: pebble NOT RESPONDING"
  fi
done
for c in $(docker ps --format '{{.Names}}' | grep -vE '^('"${ROCKS[*]}"')$'); do
  docker exec "$c" sh -c 'pgrep -x supervisord >/dev/null' 2>/dev/null \
    && echo "$c: docker-path OK" || echo "$c: supervisord MISSING (unexpected)"
done
echo "pebble processes host-wide (should match container count): $(pgrep -cx pebble)"
```

**Pass criteria (summary):**

1. Every container in the rocklist is up, `pebble services` reports `healthy`, and all
   services are in expected states (as in `et3-dh3-f-sw1`).
2. `pebble logs` (and `docker logs`) for each migrated container show no `ImportError`,
   `Traceback`, `missing ... .so`, `undefined symbol`, or repeated `SIGx`/`crash`.
