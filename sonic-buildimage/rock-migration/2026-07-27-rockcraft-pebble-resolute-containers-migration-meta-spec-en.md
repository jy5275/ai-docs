# Rockcraft + Pebble Migration: Resolute Containers Meta-Spec

**Date:** 2026-07-27

**Branch:** `202605_resolute_rock`

**Scope:** All SONiC containers on `vs` and `broadcom` providing basic network functionality.

**Reference:** `feature_noble_build` branch (Noble implementation, consulted but not copied).

## 1. Goal

Migrate 17 containers from Dockerfile + supervisord to Rockcraft + Pebble on the
`202605_resolute_rock` branch (Ubuntu 26.04 / Resolute). Both the Dockerfile path and
the new Rockcraft path must coexist in the same branch for every container.

The results are pushed in this PR: https://github.com/canonical/sonic-buildimage/pull/9.
Before analysis and doing actual jobs, check if local repos and PR are in sync, and how many containers have already been migrated.

## 2. Container Inventory and Migration Order

Migration is done one container at a time. Each container gets its own
implementation plan (via the writing-plans skill) referencing this meta-spec for the
common pattern.

| Order | Container | Base image | Difficulty | Key challenge |
|-------|-----------|-----------|-----------|---------------|
| — | ~~dockers/docker-mux~~ | config-engine | — | **Not migrated**: does not run on SONiC; excluded from this spec |
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

**Note on 202605-new containers**: docker-sysmgr and docker-stp are new in the 202605
branch (no upstream Noble reference). They are simple config-engine based containers
and follow the standard pattern without special difficulty.

## 3. Architecture Overview

Each container's migration follows the same pattern: flatten the
Docker three-layer inheritance chain (`docker-base-resolute` → `docker-config-engine-resolute`
/ `docker-swss-layer-resolute` → specific container) into a single `rockcraft.yaml`.

Key decisions (consistent with docker-eventd, applying to all 17 containers):

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

### 3.1 `build-packages` vs `stage-packages`

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

### 3.3 Non-example: `docker-database`
`docker-database` is a fully chiselled rock, with bare base (instead of ubuntu base) and 
`stage-packages` all slices names (instead of all package names). Other rocks' dependencies
haven't been fully chiselled in chisel-releases yet, so don't follow `docker-database`'s 
migration pattern.

## 4. Files shared by all containers (already in place)

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
four migrations:

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

All containers follow this three-part skeleton.

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
      # libnl-3/genl/route/nf come along as hard Depends of libnl-cli-3-200
      - libnl-cli-3-200
      # <container-specific packages>
    
    prime:
      # Exclude unnecessary artifacts that `source: .` dumps at the rock root
      - -files
      - -envs
      - -python-debs
      - -vcache
      - -base_image_files
      - -buildinfo
      - -Dockerfile*
      - -supervisord.conf
      - -critical_processes

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

- **Noble reference deviation**: Noble's rockcraft.yaml files use many per-deb parts
  (`install-<deb>_<version>_amd64`) plus a large `install-common-files` part that copies
  everything via `cp` in `override-prime`. Resolute improves on this: a single
  `setup-<name>` part installs all debs via `dpkg -x` and places files via `organize`.
- **`organize` over `cp`**: Source file placement uses `organize` (declarative) rather
  than `cp` in `override-build`/`override-prime`. The only exceptions are `rsyslog.conf`
  (the `rsyslog` stage-package overwrites it with a default config, so it must be copied
  in `override-prime` after staging) and `manifest.json` (must be at the rock root).
- `prime:` excludes the unnecessary build inputs that `source: .` dumps at the rock 
  root.
- **deb wildcards**: `dpkg -x debs/<pkg>_*.deb` avoids hardcoding version numbers.
- **python symlink**: not needed. The `python3-minimal` apt package (pulled in by
  `stage-packages: [python3]`) already provides `/usr/bin/python3 -> python3.14`.
- **add-user part**: Creates the `syslog` user/group needed by rsyslog, using
  `overlay-script` in the overlay chroot where `/etc/passwd` and `/etc/group` come from
  the `ubuntu@26.04` base.

### 5.2 Authoring principles

- **Keep it lean.** `rockcraft.yaml` should be as minimal as possible. The
  `feature_noble_build` branch's rockcraft.yaml files may contain redundant commands or
  entries carried over from earlier migrations. For every line in a `rockcraft.yaml`, be
  able to trace its necessity back to a concrete source in the current branch — typically
  `Dockerfile.j2`, `rules/*.mk`, or other files in the same container directory. If no
  such basis exists, the line may be a candidate for removal.
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
     itself is dead weight too, but that is a different check (see §9.9's libpam note) and
     orthogonal to the dependency-closure rule here.

- **Consume stock Ubuntu packages from the archive, not from `debs/`.** Direction: all
  dependencies converge on the Ubuntu archive, which owns their versions; the build takes
  the archive's default version. A deb under `target/debs/resolute/` that is a stock
  archive package — typically a `SONIC_ONLINE_DEBS` entry fetched from
  `archive.ubuntu.com`, as opposed to a SONiC source build (`SONIC_MAKE_DEBS` /
  `SONIC_DPKG_DEBS`) — must be listed in `stage-packages`, not `dpkg -x`'d. The switch is
  consumer-first: rocks stop consuming the local copy while `rules/*.mk` stays in place for
  the Docker path and compile-time users, and is removed later in a separate change.
  - Apply the dependency-closure rule above: list only the top of the closure
    (`libnl-cli-3-200` hard-depends `(= 3.12.0-2)` on libnl-3/genl/route/nf, so it alone
    brings all five).
  - In a part that uses chisel slices (docker-database), put the package in its
    unchiselled part; slices and whole packages cannot be mixed in one part.
  - Verify equivalence before switching: `sha256sum` the local deb against
    `apt-get download <pkg>`, then build with that deb **excluded** from `debs/` and check
    that `parts/*/stage_packages/` holds the archive deb and `ldd` finds no `not found` for
    every prime ELF linking it.

- **Add necessary maintainer script logic**: packages listed under
  `stage-packages` in rockcraft.yaml are only **unpacked** (rather than installed) during 
  the `rockcraft pack` - a process similar as what `dpkg -x` does - doesn't run 
  maintainer scripts, doesn't update dpkg status database, and skip many other steps that
  a normal deb package installation would do. Therefore, some of the skipped steps are necessary to be added back in `rockcraft.yaml`, like the `add-user` part in every rock.
  If necessary, look into rockcraft's source code to find out how packages are installed
  in a rock.

- **Translation of supervisord service configuration**: in supervisord.conf, a service 
  having the config item `autostart=false` doesn't mean it not get started at bootup. 
  The event listener dependent-startup controls the starting order in supervisord. Don't be 
  cheated by a single config item, always analyze the services behavior in a container-wide view.

### 5.3 `install-python` pitfall: wheel `data_files` with relative destinations

**Root cause.** Some wheels' `setup.py` declare `data_files=[(dest, [...]), ...]` where
`dest` is a *relative* path (not starting with `/`). distutils/setuptools resolve a relative
`data_files` destination against `sys.prefix` at install time. The two paths disagree on what
`sys.prefix` is:

- **Docker path**: `pip3 install` uses the system interpreter, whose default `sys.prefix` is
  `/usr/local`. A relative destination `'yang-models'` lands at `/usr/local/yang-models`.
- **Rock path**: rockcraft's `python` plugin creates its pip environment with the rock root
  itself as the prefix (`${CRAFT_PART_INSTALL}`, effectively `/`). The same relative
  destination lands at `/yang-models` instead — a different absolute path.

**Impact and affected wheels.** Two wheels in the common skeleton's `python-packages` lists
hit this:

| Wheel | `data_files` destinations (relative) | Hardcoded consumers expecting `/usr/local/...` |
|---|---|---|
| `sonic_yang_models` | `yang-models`, `cvlyang-models` | `YANG_MODELS_DIR`/`YANG_DIR = "/usr/local/yang-models"` in `sonic_yang_cfg_generator.py`, `config_mgmt.py`, `sonic-cfg-help` |
| `sonic_frr_mgmt_framework` | `sonic/frrcfgd` | `-T /usr/local/sonic/frrcfgd` in `gen_frr.conf.j2`'s `sonic-cfggen` invocation (docker-fpm-frr `start.sh`) |

`sonic_yang_models` is part of the common config-engine wheel set every migrated container
installs (§5), so this was a **universal** defect, silently present in all 16 currently
migrated/in-progress containers, not specific to one of them — confirmed empirically by
`docker export`ing the already-shipped `docker-database` rock and finding `yang-models/` and
`cvlyang-models/` at the image root instead of under `usr/local/`. Any code path that reads
YANG models at runtime in a rock (`sonic-cfggen -y`, `config_mgmt`, CLI auto-generation) would
fail to find them. The `sonic_frr_mgmt_framework` instance of the same bug was found and fixed
first, in `docker-fpm-frr` (§9.15).

**No generic framework-level fix exists.** rockcraft's `python` plugin exposes only
`python-packages`/`python-requirements`/`python-constraints` — no pip `--prefix`/`--target`
passthrough. This isn't an oversight: the plugin's pip environment prefix is deliberately the
rock root, because Rockcraft's `sitecustomize.py` (injected to make the rock's Python
packages importable regardless of how the interpreter is invoked) hardcodes the lookup path
`/lib/python{x.y}/site-packages`. Pointing pip's prefix elsewhere (e.g. via `PIP_PREFIX`) would
move the installed *packages* out of that lookup path too and break imports entirely — a much
worse failure than the `data_files` misplacement itself.

**Fix: a declarative `organize:` entry on the `install-python` part**, not an imperative `mv`
in `override-prime`:

```yaml
install-python:
  plugin: python
  ...
  stage-packages:
    - python3-venv
  organize:
    yang-models: usr/local/yang-models
    cvlyang-models: usr/local/cvlyang-models
```

`organize` runs once per part, right after that part's build step and before stage (see
craft-parts `executor/part_handler.py`: "Organize the installed files as requested. We do
this in the build step..."), which is exactly when the python plugin's `pip install` has just
produced `yang-models`/`cvlyang-models` in `${CRAFT_PART_INSTALL}`. Its directory-to-directory
handling (`executor/organize.py`) is `link_or_copy_tree` followed by `rmtree` of the source —
behaviorally identical to a hand-written `mkdir -p && mv && rmdir`, but declarative, consistent
with the "organize over cp" principle (§5.1), and silently a no-op if the source directory is
absent (no `if [ -d ... ]` guard needed). This is strictly preferred over the `frrcfgd` fix's
original `override-prime` shell block (§9.15); both are now `organize:` entries.

The true root-cause fix — changing `sonic-yang-models`/`sonic-frr-mgmt-framework`'s `setup.py`
to use `package_data`/`importlib.resources` instead of `data_files`, which is prefix-independent
— requires editing the wheel's packaging *and* every downstream hardcoded path reader, and
affects the Docker path's file layout too. That is out of scope for the buildimage-side rock
migration and is not attempted here; `organize:` is a consumer-side correction, same spirit as
§5.2's "consume stock Ubuntu packages from the archive" rule.

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
- **Quick one-shots run inline, not as pebble services**: a command that completes in under a
  second — an init or gate script such as `restore_nat_entries.py` or `eventdb_wrapper.sh` —
  shouldn't be a pebble service started with `pebble start`. pebble treats any service that
  exits within 1-second as a *failed start*, even when it exits 0, which marks the change 
  `Error` and makes the `start` service exit non-zero. Instead, run the script directly as an
  inline command in `start.sh` at the point where it should run, so its ordering relative to
  the daemons is preserved, and drop the matching entry from the `services:` section.
  Example:
  ```bash
  pebble start natmgrd
  pebble start natsyncd
  /usr/bin/restore_nat_entries.py # Don't make restore_nat_entries a pebble service
  ```

## 7. Conditional Daemon Handling: Approach A and B

### 7.1 Approach A — static services + start.sh on-demand start (default)

**Applies to**: majority of containers

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

### 7.2 Approach B — dynamic pebble layer

**Applies to**: complex containers, like docker-dhcp-relay 
(per-VLAN relay agents, count determined at runtime, cannot be enumerated statically).

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

The remote switch `et3-dh3-f-sw1` and `dut2` may currently be running Ubuntu Resolute SONiC. 
If so, they serve as useful comparison baseline: every container on the baseline switch is 
still built from a Dockerfile, with services managed by supervisord. The objective is for 
each migrated Rockcraft + Pebble container `docker-<name>` to replicate the behavior of 
its counterpart on that baseline switch and expose the same set of services.

To choose which one to be the baseline switch: usually you should choose `et3-dh3-f-sw1` 
because it's serving production traffic so always has more stable SONiC version installed.
In contrast, `dut2` is just a testing device. However, if you need to modify switch status
(e.g. run `sudo config feature state xxx enabled`), you should always use `dut2`.

Before authoring the `stage-packages` list in `rockcraft.yaml`, inspect the packages actually
installed in the corresponding container on baseline switch to ensure the rock's runtime
environment matches.

Both `et3-dh3-f-sw1` and `dut2` must be accessed throught company VPN. A connection
timeout may suggest company VPN has been turned on. If you're unable to turn it on 
yourself, stop and ask me to turn it on manually.

If neither `et3-dh3-f-sw1` nor `dut2` is running Ubuntu Resolute SONiC in a good state,
don't fix them, try to complete the migration without a comparison baseline.

## 9. Per-Container Migration Notes

Only what a container does **differently** from §5–§7 and cannot be read off its
`services` / `stage-packages` / `organize` / `python-packages` lists — read those in
`dockers/<name>/rockcraft.yaml`. 

Not repeated per entry: every swss-layer rock also
`dpkg -x`'s the swss-layer debs (libsairedis, libsaimetadata, libteam5, libteamdctl0,
libnexthopgroup, libdashapi, swss).

### 9.1 docker-macsec — migrated

- start.sh is rock-only (the Dockerfile does not copy it) and holds only the pebble branch.
- `etc/wpa_supplicant.conf` and `cli/` land by `source: .` path, not `organize`; `prime:`
  additionally drops `cli-plugin-tests`.
- wpasupplicant made usr-merge clean at the source (§12.1).
- Installed as a native docker image, not an SPM package (§4.2; done).
- `install-python` `organize:`s `yang-models`/`cvlyang-models` to `usr/local/{yang,cvlyang}-models` (§5.3).

### 9.2 docker-teamd — migrated

- teammgrd `kill-delay: 60s` (supervisord `stopwaitsecs=60`); teamsyncd's `startsecs=5`
  has no pebble equivalent — it is only started after teammgrd in start.sh.
- Extra deb: `libteam-utils`.
- `install-python` `organize:`s `yang-models`/`cvlyang-models` to `usr/local/{yang,cvlyang}-models` (§5.3).

### 9.3 docker-iccpd — migrated

- `iccpd.sh` is the service command: mclagsyncd in background, iccpd in foreground.
- `chmod +x start.sh iccpd.sh` in `override-build` (both are 100644 in git; the Dockerfile
  does the same chmod).
- `override-prime` creates `iptables`/`ebtables` → `xtables-nft-multi` symlinks (postinst
  never runs in a rock).
- `rules/docker-iccpd.mk` gained `_PACKAGE_NAME = iccpd`. No `critical_processes` file.
- `install-python` `organize:`s `yang-models`/`cvlyang-models` to `usr/local/{yang,cvlyang}-models` (§5.3).

### 9.4 docker-sflow — migrated

- start.sh is rock-only.
- `override-build` seds `DAEMON_ARGS` in `etc/init.d/hsflowd` (mirrors the Dockerfile).
- hsflowd made usr-merge clean at the source (§12.1).
- `install-python` `organize:`s `yang-models`/`cvlyang-models` to `usr/local/{yang,cvlyang}-models` (§5.3).

### 9.5 docker-sysmgr — not migrated

- Single daemon `/usr/bin/rebootbackend`; no start.sh — create one. `sysmgr.sh` is not
  copied by the Dockerfile, so do not add it (§5.2).
- The `/var/run/dbus` mount comes from `rules/docker-sysmgr.mk` RUN_OPT, rendered by the
  host-side `docker_image_ctl.j2` for both paths — nothing to do in the rock.
- `Dockerfile.j2` seds `%syslogtag%` into `/etc/rsyslog.conf`; decide whether the rock
  needs the same.

### 9.6 docker-stp — not migrated

- The existing start.sh is used by the Docker path and calls `supervisorctl start`; keep
  those calls outside the pebble branch and add `pebble start stpd; pebble start stpmgrd`
  inside it. rsyslogd is `startup: enabled`, so do not start it from start.sh.
- The Dockerfile's `libpython3.11` becomes `libpython3.14`; stage it explicitly — `python3`
  does not pull it in.
- Same `%syslogtag%` rsyslog.conf sed as sysmgr.

### 9.7 docker-nat — migrated

- `restore_nat_entries.py` runs inline in start.sh after natsyncd, not as a service (§6).
- `override-prime` creates the iptables/ip6tables/ebtables/arptables family symlinks →
  `xtables-nft-multi` (organize cannot create symlinks).
- `install-python` `organize:`s `yang-models`/`cvlyang-models` to `usr/local/{yang,cvlyang}-models` (§5.3).

### 9.8 docker-lldp — migrated

- lldpd command is the single-ASIC form; the multi-ASIC (`namespace_id`) branch of
  `supervisord.conf.j2` is not reproduced.
- `waitfor-lldp-ready` is kept as a pebble gate service, not inline (benign "exited
  quickly", §12.3).
- `override-build` removes the packaged `etc/default/lldpd` so the container's own copy
  (via `organize`) wins.
- `add-user` also creates the `_lldpd` user/group. Consumes `IMAGE_VERSION` (§3.2).
- `lldp_syncd` comes from the `sonic_d` (DBSYNCD_PY3) wheel.
- `install-python` `organize:`s `yang-models`/`cvlyang-models` to `usr/local/{yang,cvlyang}-models` (§5.3).

### 9.9 docker-sonic-gnmi — migrated

- Extra debs: `sonic-mgmt-common` (CVL schema `/usr/sbin/schema/`, `cvl_cfg.json`,
  required by `CVL_SCHEMA_PATH` in gnmi-native.sh/dialout.sh) and `sonic-gnmi`
  (`telemetry`, `dialout_client_cli`, `/usr/models/yang/`).
- `libxml2`/`libevent-2.1-7` are not needed (`objdump -p` shows no NEEDED entry).
  `libpam.so.0` is supplied by the `ubuntu@26.04` base layer, so it must **not** be a
  stage-package: rockcraft drops the staged copy during PRIME as a duplicate of the base.
  Confirm a library is absent from the base before adding it.
- Consumes `IMAGE_VERSION` (§3.2).
- `install-python` `organize:`s `yang-models`/`cvlyang-models` to `usr/local/{yang,cvlyang}-models` (§5.3).

### 9.10 docker-snmp — migrated

- Top-level `environment: PYTHONOPTIMIZE: "1"`.
- `sysDescr_pass.py` is extracted from the asyncsnmp wheel with `unzip -p` in
  `override-build` (build-package `unzip`), not via `python3 -m sonic_ax_impl install`.
- `install-python` build-packages `python3-dev`, `gcc`, `make` (hiredis compile).
- `add-user` also creates `Debian-snmp`. Consumes `IMAGE_VERSION` (§3.2).
- Gap: the chassis-packet `--enable_dynamic_frequency` branch of snmp-subagent is not
  reproduced.
- `install-python` `organize:`s `yang-models`/`cvlyang-models` to `usr/local/{yang,cvlyang}-models` (§5.3).

### 9.11 docker-dhcp-server — not migrated

- `dhcpservd-ready` (`wait_for_dhcpservd.sh`) is a gate of up to 120s; kea-dhcp4 must start
  only after it exits, so `pebble start` order alone is not enough — poll the gate from
  start.sh (as fpm-frr does for zsocket).
- kea-dhcp4 needs `KEA_PIDFILE_DIR=/tmp/` (supervisord `environment=`): a justified
  service-level `environment:` exception.
- `docker_init.sh` dir creation/chmod moves into start.sh. Consumes `IMAGE_VERSION`.
- psutil compile needs `python3-dev` + `build-essential` as `install-python`
  build-packages. Native-image install (§4.2) already done.

### 9.12 docker-dhcp-relay — not migrated

- Approach B (§7.2): per-VLAN agents from a `pebble-layer.j2`; `.dep` must also
  filter-out `pebble-layer.j2`.
- `docker_init.sh` also renders `wait_for_intf.sh.j2` and `port-name-alias-map.txt.j2`;
  `start.sh` counts agents with `supervisorctl status | grep "^dhcp-relay:"` — needs a
  pebble equivalent. Consumes `IMAGE_VERSION`. Native-image install (§4.2) already done.

### 9.13 docker-orchagent — not migrated

- `docker-init.j2` is rendered at build time with `ENABLE_ASAN`, and at runtime renders
  `supervisord.conf.j2` (20 programs, heavily conditional), `critical_processes.j2` and
  `watchdog_processes.j2` — the same shape that pushed pmon and fpm-frr to approach B
  (§7.3); evaluate B before A.

### 9.14 docker-platform-monitor — migrated

- **Approach B** (§7.3 fallback taken): services live in `pebble-layer.j2`, rendered and
  added by start.sh; `rockcraft.yaml` declares only rsyslogd/start. `.dep` also
  filter-outs `pebble-layer.j2`.
- start.sh is rock-only (the Docker path keeps `docker_init.j2` as entrypoint, excluded
  from prime): no `pgrep -x pebble` branch, keeps only the `sonic_platform` wheel install
  from `docker_init.j2`; mellanox/aspeed/bluefield detection dropped (vs/broadcom only).
- `delay` is a gate service polled from start.sh; daemons are started in a fixed-order
  loop with `|| true`. Long-running daemons use `on-success: ignore` to mirror
  supervisord `autorestart=unexpected`.
- Own rsyslog.conf: `override-build` removes the packaged one, `override-prime` copies
  `etc/rsyslog.conf` from the container dir.
- No grpc `.so` strip. `install-python` build-packages `python3-dev gcc g++ make`.
- Known benign failure: `chassis_db_init` on VS (§12.2).
- `install-python` `organize:`s `yang-models`/`cvlyang-models` to `usr/local/{yang,cvlyang}-models` (§5.3).

### 9.15 docker-fpm-frr — migrated

- **Approach B** (§7.3 fallback taken): `pebble-layer.j2` with command-level conditions
  (e.g. `bgpd -M bmp`), `kill-delay: 0s` for supervisord `stopsignal=KILL`. `.dep` also
  filter-outs `pebble-layer.j2`.
- start.sh is rock-only (the Docker entrypoint stays `docker_init.sh`, excluded from
  prime) and absorbs `docker_init.sh`: `/var/{log,lib,run}/frr` ownership, the 4 config
  modes, default-gateway metric, `sr0` dummy interface. `zsocket` is a gate service
  polled from start.sh.
- `override-build` copies the `frr/` template tree with `cp -a`; `install-python`
  `organize:`s `sonic/frrcfgd` to `usr/local/sonic/frrcfgd` (§5.3, same `data_files`
  pitfall as `sonic_yang_models`) and rewrites console-script shebangs to
  `/usr/bin/python3`.
- `add-user` creates `frr` (uid/gid 300, from `rules/config`) and `frrvty`.

### 9.16 platform/broadcom/docker-syncd-brcm — not migrated

- Services: syncd (`/usr/bin/syncd_start.sh`) **and** ledinit (`/usr/bin/start_led.sh`).
  Also ships start.sh, `bcmsh`, `rdb-cli`. Survey `Dockerfile.j2` and the `.mk` first.

### 9.17 platform/vs/docker-syncd-vs — not migrated

- Not in `build_rocks.sh` (also commented out on Noble). Its Dockerfile installs
  `libnl-3-dev`/`libnl-route-3-dev` debs — take them from the archive (§5.2).

## 10. Files to Create / Modify (per container)

Each container migration touches:

### 10.1 New files

| File | Description |
|------|-------------|
| `<container>/rockcraft.yaml` | Rockcraft manifest (from section 5 skeleton) |
| `<container>/pebble-layer.j2` | Dynamic pebble layer template |
| `<container>/start.sh` | **Only containers without one**: docker-macsec, docker-sflow (create with pebble branch) |

### 10.2 Modified files

| File | Change |
|------|--------|
| `<container>/start.sh` | Append pebble detection and orchestration block (for containers with existing start.sh) |
| `build_rocks.sh` | Append `"<container>"` to rocklist |
| `rules/docker-<name>.dep` | `filter-out` the rockcraft.yaml and `pebble-layer.j2` from the dependency list (see §4.2) |
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

sudo qemu-system-x86_64 -enable-kvm -cpu host -m 8192 -smp 4 -boot order=c -name sonic \
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

# After all testing, shutdown the VM gracefully
sshpass -p 'YourPaSsWoRd' ssh -p 2200 admin@127.0.0.1 'sudo shutdown -h now'
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
| database, lldp, … (every container in `build_rocks.sh` rocklist) | yes | `azure-labels=0`, `pebble services` returns a non-empty plan |
| swss, syncd, … (everything else) | no | `azure-labels>=1`, `docker exec <c> supervisorctl status` works |

#### 11.6.3 Expected pebble service state (per migrated container)

Every rock exposes the same skeleton plus its container-specific daemons. `rsyslogd` is
`startup: enabled` and `active`; `start` is `startup: enabled` but `inactive` after its
initial run.
Daemon services have `startup: disabled` in the plan — whether they end up `active` is
decided by `start.sh` reading runtime config. Run and compare:

```bash
docker exec <container> pebble services
```

If any service is in `backoff` or `error` state, that should be an error — except pmon's
pre-existing `chassis_db_init` on VS, which exits 1 (no chassis / no platform API, identical
to the Docker path) and is treated as benign (§12.2, §11.6.4 exclusion).

Each service's state should match the respecitve service's state on respecitve container on
the baseline remote switch. For example, if `docker exec database supervisorctl status redis` 
on baseline switch is active/inactive, then `docker exec database pebble services redis` 
on our VM must show similar state (although pebble and supervisord may use different terminologies).


#### 11.6.4 Log checks (per migrated container)

For each rock container, run the two checks 

1. Pebble doesn't have error operations

   ```bash
   docker exec <c> pebble changes           # every Spawned start change must be status Done, no Error
   docker exec <c> pebble checks            # health-check config sanity (no checks in this skeleton)
   docker exec <c> pebble health            # overall: healthy
   ```

2. Logs — no `ImportError`, `Traceback`, `cannot open shared object file`, `undefined symbol`,
   `exited quickly with code 0, will ignore`, `bad interpreter` or crash loop:

   ```bash
   docker exec <c> pebble logs            # all buffered service logs (30 lines default)
   docker exec <c> pebble logs <service>  # one service; add -n=all for the complete buffer
   ```

   Fall back to `docker logs` for the same stream if `pebble logs` shows nothing. Filtering
   only the error keyword listed above. Do **not** flag as defects the benign noise seen 
   routinely on a healthy VS image:

   - `rsyslogd: omrelp ... error opening connection to remote peer` — expected when no
     central syslog server is reachable;
   - `... 'events' list is missing or empty. Skipping ...` — normal.
   - `gnmi-native` startup `jinja2.exceptions.UndefinedError: 'GNMI' is undefined` from
     `telemetry_vars.j2` — telemetry/GNMI is not configured on a default VS config; the
     native gNMI server falls back to default args and stays `active` (matches Docker path).
- pmon `chassis_db_init` in `error` state — on VS `import sonic_platform.platform` fails
      (VS ships its platform API host-only, and its platform dir has no `sonic_platform`
      wheel to install at runtime). The Docker-path supervisord also starts it (via the
      `dependent-startup` listener) but records the exit-1 as a silent `EXITED`
      (`autorestart=false`), so it was never noticed. Pre-existing, not a migration defect
      (§12.2).


#### 11.6.5 Scripted pass/fail harness

Run once per image to get one-line signal per container. Fill `ROCKS` with the container
names of the current `build_rocks.sh` rocklist:

```bash
#!/usr/bin/env bash
# Verify rock/pebble containers under a booted SONiC vs image.  Args: none.
set -u
ROCKS=(database lldp ...)   # container names of the build_rocks.sh rocklist
# Real defect markers only (see §11.6.4 for the benign-noise exclusion list).
DEFECTS='ImportError|Traceback|cannot open shared object file|undefined symbol|panic|bad interpreter:'
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
   services are in expected states (as in baseline switch).
2. `pebble logs` (and `docker logs`) for each migrated container show no `ImportError`,
   `Traceback`, `missing ... .so`, `undefined symbol`, or repeated `SIGx`/`crash`.

## 12. Working Notes

### 12.1 `dpkg -x` symlink clobbering and usrmerged deb payloads

Recorded during §11 verification of docker-macsec and docker-sflow. Their debs are split
across `setup-<name>` (`plugin: dump`, `dpkg -x`) and `install-python` (`plugin: python`,
wheels). On `ubuntu@26.04` the pack failed at the **stage** step:

```
craft_parts.errors.PartFilesConflict: Failed to stage: parts list the same file with
different contents or permissions.
Parts 'install-python' and 'setup-macsec' list the following files, but with different
contents or permissions:
    lib
    sbin
```

**Cause.** On 26.04 rockcraft usrmerges each part's install dir by default — before each part
builds it pre-populates `bin → usr/bin`, `lib → usr/lib`, `sbin → usr/sbin`, … symlinks — but
**skips the `dump`/`nil` plugins** (24.04 and older never usrmerge, which is why they pack
cleanly). So `install-python`'s top-level `sbin`/`lib` are symlinks while `setup-macsec`'s
`dpkg -x` of `wpasupplicant_*.deb` emits real top-level `sbin/`/`lib/` directories, and the
stage step (`craft_parts/executor/collisions.py::paths_collide()`) rejects the
symlink-vs-directory mismatch.

Pre-creating the symlinks doesn't help: `dpkg -x` (`dpkg-deb --extract`) replaces any
pre-existing symlink with a real directory, and `enable-usrmerge` is clobbered before
priming — neither is a workaround.

**Fix.** Make the offending deb usr-merge clean at the source, so the dump part no longer
emits top-level `sbin/`/`lib/`:

- macsec: `sonic-wpa-supplicant` gitlink bumped to a usr-merge fix so wpasupplicant installs
  under `/usr/sbin`/`/usr/lib` (commit `f5216636f`).
- sflow: `hsflowd` build patched (`0010` sets `SYSTEMDDIR`) so its systemd unit installs under
  `/usr/lib/systemd/system` (commit `8f541664f`).

Only debs carrying legacy top-level `sbin/`/`lib/` payload needed a fix: macsec
(`wpasupplicant`), sflow (`hsflowd`); debs already under `usr/…` needed nothing. An earlier
post-extract relocation hack was superseded by this source-level usr-merge and dropped.

Diagnose `PartFilesConflict` by checking both parts' install dirs:
`lxc --project rockcraft exec <instance> -- ls -ld /root/parts/<part>/install/{sbin,lib}`.

### 12.2 pmon: `chassis_db_init` stayed in `error` on VS (pre-existing; left unfixed)

> Status: investigated and understood, but **deliberately left as-is** on the VS rock.
> Record of symptoms + verified cause so a future agent can pick this up without re-deriving it.

**Symptom.** On the migrated VS rock, `pebble services chassis_db_init` reports the service in
`error` state at §11.6 verification. It is classified as benign VS noise (§11.6.4), but we
kept the pebble `error` state rather than masking it.

**What the service does.** `chassis_db_init` is a one-shot (not a long-running daemon) that
populates the `CHASSIS_INFO` table in STATE_DB with chassis hardware metadata — `serial`,
`model`, `revision`, `module_num` (plus `switch_host_serial` on BMC). It only matters for
modular-chassis box management; a fixed-config box and the virtual switch have no chassis to
report, so nothing downstream consumes this data on VS.

**Root cause (verified, not a migration regression).**

1. `chassis_db_init` hard-fails if it cannot load the platform API
   (`src/sonic-platform-daemons/sonic-chassisd/scripts/chassis_db_init:107-112`):
   ```
   try:
       import sonic_platform.platform
       platform_chassis = sonic_platform.platform.Platform().get_chassis()
   except Exception as e:
       log.log_error("Failed to load chassis due to {}".format(repr(e)))
       sys.exit(CHASSIS_LOAD_ERROR)  # = 1
   ```
2. VS never puts `sonic_platform` into the pmon container. `sonic-platform-vs`
   (`platform/vs/sonic-platform-modules-vs/`) is built with
   `python3 setup.py install --install-layout=deb` in its `debian/rules`
   (`binary-indep`), which scatters the package as `.py` files into the **host**
   `dist-packages` only — it produces no wheel and drops nothing into the platform dir.
   VS also defines no `SONIC_PLATFORM_API_PY3` (only mellanox / alpinevs / nvidia-bluefield
   do), so `rules/docker-platform-monitor.mk:15`'s `_PYTHON_WHEELS += $(SONIC_PLATFORM_API_PY3)`
   evaluates empty for VS.
3. All three init scripts share the same runtime fallback — if `import sonic_platform` fails,
   `pip` install `sonic_platform-1.0-py3-none-any.whl` from `/usr/share/sonic/platform/`
   (`docker_init.j2` / `rock_init.sh` / `start.sh:51-66`). On VS that path has no wheel
   (`device/virtual/.../` contains no `*.whl`), so the install no-ops and the import still
   fails.
4. **Broadcom contrast (verified on `dut2`).** Real hardware platform-module debs ship the
   wheel explicitly as a data file, e.g. Dell S5232F
   (`platform/broadcom/sonic-platform-modules-dell/debian/platform-modules-s5232f.install:8`):
   ```
   build-s5232f/sonic_platform-1.0-py3-none-any.whl  usr/share/sonic/device/x86_64-dellemc_s5232f_c3538-r0
   ```
   The host platform dir is bind-mounted into the pmon container as `/usr/share/sonic/platform`
   (`files/build_templates/docker_image_ctl.j2:816`), so on `dut2`
   (`DEVICE_METADATA.localhost.platform = x86_64-dellemc_s5232f_c3538-r0`) the fallback finds the
   wheel, installs it, and `import sonic_platform` succeeds. Because VS has no such wheel,
   the same code path fails there.

   Independent second-order blocker: VS `sonic_platform/chassis.py` reads
   `/etc/sonic/vs_chassis_metadata.json` in `Chassis.__init__` and raises `FileNotFoundError`
   if absent — that file is not present by default on VS. So even a successful `import` would
   fail for VS without further setup; this confirms VS genuinely has no chassis to initialise.

**How the service gets started (both paths start it — do not assume "rendered but never
auto-started").**

- Docker/supervisord path: `[program:chassis_db_init]` has `autostart=false` +
  `dependent_startup=true` + `dependent_startup_wait_for=rsyslogd:running`
  (`docker-pmon.supervisord.conf.j2:75-87`). SONiC registers an event listener
  `[eventlistener:dependent-startup]` running `python3 -m supervisord_dependent_startup`
  (conf `:6-13`). That plugin (a pip-installed wheel, present in the container at
  `…/dist-packages/supervisord_dependent_startup/`) explicitly starts every service that is
  `autostart=false` + `dependent_startup=true` once its `wait_for` dependency reaches RUNNING,
  in priority order. So `chassis_db_init` **is** started on the Docker path too — the earlier
  note "never auto-started" was wrong.
- Rock/pebble path: `start.sh:134` loops over the rendered services and runs
  `pebble start <svc>` unconditionally, so `chassis_db_init` is started here as well.

The only difference is how a failed one-shot is *reported*: supervisord with
`autorestart=false` records `exited (exit status 1; not expected)` and leaves the program
`EXITED` — silent, non-blocking, easily overlooked (which is why this was never noticed on
the Docker path; on `dut2`, where the import succeeds, the log shows
`exited (exit status 0; expected)`). pebble instead marks the exit-1 service `error`
(compounded by `on-failure: ignore`), surfacing it in §11.6.

`chassis_db_init` is rendered unconditionally in `pebble-layer.j2:24` — unlike `chassisd`,
which is gated by `not skip_chassisd and (IS_MODULAR_CHASSIS == 1 or is_smartswitch)`
(`pebble-layer.j2:17`). And `device/virtual/x86_64-kvm_x86_64-r0/pmon_daemon_control.json`
`skip`s six daemons (`ledd`/`xcvrd`/`pcied`/`psud`/`syseepromd`/`thermalctld`) but has no
`skip_chassis_db_init`, so nothing filters it on VS.

**Conclusion / constraint.** Pre-existing VS behavior (identical across Docker, 24.04 rock,
and 26.04 rock paths), not a rock-migration regression. Do **not** "fix" it by editing
`device/virtual/...` — that directory (and `pmon_daemon_control.json`) is shared with the
Docker path and out of scope for a container migration; an earlier attempt to add
`skip_chassis_db_init` there was reverted for that reason. Any future fix must live in the
rock/pebble layer only (e.g. gate `chassis_db_init` behind the same modular-chassis condition
as `chassisd`, or `skip` it via the rock's own daemon-control path) if it is ever revisited;
as of now it is intentionally left alone.

### 12.3 gnmi-native: `UndefinedError: 'GNMI' is undefined` (benign)

At boot (telemetry not configured on the default VS config) gnmi-native logs this traceback;
it falls back to default args and stays `active`. Pre-existing; benign (§11.6.4).
