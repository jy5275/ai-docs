# Migrating a SONiC Container from Dockerfile + supervisord to Rockcraft + Pebble + Chisel

**A docker-database Case Study on Ubuntu Resolute (26.04)**

**Date:** 2026-08-11

---

## 1. Introduction

### 1.1 What this guide is

This is a hands-on migration guide. It walks through the `docker-database`
container's migration from a Dockerfile + supervisord packaging to a Rockcraft
manifest + Pebble services + Chisel slices rock, step by step, using the real
source files in the `sonic-buildimage` tree as the worked example.

The goal is not to document docker-database itself, but to teach the
**method** so you can apply it to your own SONiC container.

### 1.2 Who this is for

Software and network engineers who:

- Are comfortable with SONiC, container networking, and the existing
  Dockerfile-based build graph.
- Already understand the basic concepts behind Rockcraft, Pebble, and Chisel
  and now want a concrete, end-to-end recipe.

### 1.3 The two layers of change

The migration consists of two layers of work that together establish the
pattern every later container migration follows:

| Layer | Scope | Files touched |
|-------|-------|---------------|
| **Build infrastructure** (shared plumbing reusable by all rock containers) | Common files that every rock container needs | `files/rsyslog/syslog-layer.yaml` (new), `rules/scripts.mk`, `rules/scripts.dep`, `rules/docker-config-engine-resolute.mk`, `files/build_templates/docker_image_ctl.j2`, `.gitignore` |
| **docker-database itself** (the container-specific rock) | The per-container rock manifest, init script, and build script | `dockers/docker-database/rockcraft.yaml` (new), `dockers/docker-database/docker-database-init.sh` (modified), `build_rocks.sh` (new) |

The infrastructure layer is reusable by every
subsequent container; the docker-database layer is the per-container work.
When you migrate your own container you will mostly produce changes that look
like the second layer, and only touch the infrastructure layer if your
container needs a *new* shared file.

### 1.4 Scope of the docker-database migration

- **VS / single-ASIC only.** The rock starts a single static Redis instance.
  Multi-ASIC and VoQ chassis dynamic-instance generation (which the
  Dockerfile path does by rendering `supervisord.conf.j2` per instance) is
  **not** reproduced by the rock's static Pebble services.
- **Coexistence.** The existing Dockerfile path is untouched and still
  builds `target/sonic-vs.img.gz`. The rock path is an *additional* build
  that runs after `make` completes. Both must work from the same branch.

---

## 2. Phase 0 — Prerequisites & Mental Model

### 2.1 Build environment

You need, on the host that will run `build_rocks.sh`:

- **LXD** initialized (`lxd init` with a storage pool and a `lxdbr0` bridge;
  Rockcraft builds inside an LXC container).
- **Rockcraft** (the docker-database migration used Rockcraft 1.19.2). Install
  via snap: `sudo snap install rockcraft`.
- **skopeo** is not called directly; Rockcraft ships a bundled
  `rockcraft.skopeo` used to convert the `.rock` OCI archive into the Docker
  daemon.
- **Docker** daemon (the script ends with `docker save | pigz`).
- A completed `make target/sonic-vs.img.gz` run — the rock build *consumes*
  `target/debs/resolute/`, `target/files/resolute/`, and
  `target/python-wheels/resolute/`. Rockcraft is not integrated into the
  Makefile build graph; `build_rocks.sh` is a standalone, host-side script
  run manually after `make` finishes.

### 2.2 Chiselled rock mental model (`base: bare`)

The docker-database rock uses bare base, instead of a full Ubuntu filesystem.
```yaml
base: bare
build-base: ubuntu@26.04
```

`base: bare` means the rock's root filesystem contains **only what you
explicitly stage into it** — there is no base Ubuntu layer. You assemble the
rootfs from two sources:

1. **Chisel slices** (`stage-packages` entries like `bash_bins`,
   `redis-server_bins`, `python3.14_standard`) — these are fine-grained
   cuts of Ubuntu packages that extract only the files you need (e.g.
   `bash_bins` gives you `/usr/bin/bash` without bash's docs/locale).
2. **Full packages** (`rsyslog`, `rsyslog-relp`, `libpython3.14`, etc.) in a
   *separate* part, because Rockcraft forbids mixing slices and full packages
   in the same `stage-packages` list.

With base base, the resulting image is
small and contains only what you want. But you are responsible for
listing every runtime dependency that the Dockerfile got "for
free" from the base image. Some packages currently lack chisel slices and
are staged as full apt packages in a separate part; the ultimate goal is to chisel
all of them eventually so that separate part disappears.


### 2.3 Coexistence principle

The guiding constraint: **the Dockerfile path must keep working unchanged.**
Concretely:

- `Dockerfile.j2`, `supervisord.conf.j2`, `critical_processes.j2` are **not
  modified**.
- The shared init script `docker-database-init.sh` *is* modified, but in a
  backward-compatible way (a `USE_PEBBLE` branch), so the supervisord path
  still works.
- The only other shared file modified is `files/build_templates/docker_image_ctl.j2`,
  made to recognize both pebble and supervisord for readiness checks.
- New rock-specific files get new names or live in new locations.

---

## 3. Phase 1 — Analyze the Docker Layer Chain

Rockcraft `base: bare` has
no image layers, so the three-stage Docker inheritance chain must be
flattened into one `rockcraft.yaml`.

### 3.1 The chain

```
docker-base-resolute       (FROM ubuntu:resolute)
        └── docker-config-engine-resolute  (FROM docker-base-resolute)
                    └── docker-database    (FROM docker-config-engine-resolute)
```

For each layer, read its `Dockerfile.j2` and the corresponding
`rules/*.mk` file, and enumerate four categories of content:

1. **apt packages** (`apt-get install`, and `rules/*.mk` `$(...)_DEPENDENT_PACKAGES`)
2. **pip packages** (`pip install`, and `$(...)_PYTHON_WHEELS`)
3. **SONiC-built debs** (`dpkg -i` / `dpkg -x` of packages produced by the build)
4. **Files** (`COPY` / `organize` — templates, scripts, configs)

Then classify each item:

- **Needed** by the rock runtime → goes into `rockcraft.yaml`.
- **Not needed** because it's supervisord-specific
  (`supervisord`, `supervisord-dependent-startup`,
  `sonic-supervisord-utilities-rs`, `supervisord.conf.j2`,
  `critical_processes.j2`, `etc/supervisor/...`) → **drop**.
- **Build-only** (`build-essential`, `python3-dev`, `apt-utils` — installed
  then purged in the Dockerfile) → **drop**; Rockcraft builds in a
  build-base and only primes runtime files.
- **Duplicate** across layers (e.g. `libswsscommon`, `sonic-db-cli` appear in
  both layer 2 and layer 3) → **deduplicate** to one entry.

### 3.2 The resulting map (docker-database)

Here is the flattened map that produced the `rockcraft.yaml` in the source
tree. Use this as a template for your own container's analysis.

| Source layer | Item | Classification | Rockcraft landing |
|---|---|---|---|
| L1 base | `rsyslog`, `rsyslog-relp` | needed (full pkg) | part `install-unchiselled-packages` `stage-packages` |
| L1 base | curl, less, perl, procps, python3, vim-tiny, iproute2, net-tools, jq, libzmq5, libwrap0, libatomic1, libdaemon0, libdbus-1-3, libjansson4, redis-tools, libhiredis, libuuid1 | needed (subset as slices) | part `setup-database` `stage-packages` (chisel slices) |
| L1 base | `supervisord`, `supervisord-dependent-startup` | drop (supervisord) | — |
| L1 base | `socat` (SONiC deb) | needed | `dpkg -x` in `override-build` |
| L1 base | `etc/rsyslog.conf` | needed | copied in `override-prime` from `${CRAFT_PROJECT_DIR}/files/rsyslog.conf` |
| L1 base | `etc/rsyslog.d/supervisor.conf`, `etc/supervisor/...` | drop (supervisord) | — |
| L1 base | `pip.conf`, `sources.list` | drop (no apt in `base: bare`) | — |
| L2 config-engine | `python3-redis`, `python3-yaml` | needed | (covered by `python3.14_standard` slice + pip wheels) |
| L2 config-engine | `pyangbind==0.8.7` | needed | `install-python` part (`python` plugin) |
| L2 config-engine | `build-essential`, `python3-dev`, `apt-utils`, `python3-cffi` | drop (build-only / unused at runtime) | — |
| L2 config-engine | `libswsscommon`, `libyang3`, `python3-libyang`, `python3-swsscommon`, `sonic-db-cli`, `sonic-eventd` (SONiC debs) | needed | `dpkg -x` in `override-build` |
| L2 config-engine | `sonic-supervisord-utilities-rs` | drop (supervisord) | — |
| L2 config-engine | wheels: `sonic_py_common`, `sonic_yang_mgmt`, `sonic_yang_models`, `sonic_containercfgd`, `sonic_config_engine` | needed | `install-python` part (`python` plugin) |
| L2 config-engine | `sonic_supervisord_utilities` (wheel) | drop (supervisord) | — |
| L2 config-engine | `files/swss_vars.j2`, `files/readiness_probe.sh`, `files/container_startup.py` | needed | `organize` |
| L2 config-engine | `rsyslog.conf`, `syslog-layer.yaml` (new) | needed | `syslog-layer.yaml` via `organize`; `rsyslog.conf` via `override-prime` |
| L3 database | `redis-server` | needed | `redis-server_bins` slice |
| L3 database | `redis-tools` | dedup with L1 | (covered by slices) |
| L3 database | `click` (pip) | needed | `install-python` part (`python` plugin) |
| L3 database | `libdashapi` (SONiC deb) | needed | `dpkg -x` in `override-build` |
| L3 database | `libswsscommon`, `sonic-db-cli` (SONiC debs) | dedup with L2 | single `dpkg -x` entry |
| L3 database | `supervisord.conf.j2`, `critical_processes.j2` | drop (supervisord) | — |
| L3 database | `database_config.json.j2`, `database_global.json.j2`, `multi_database_config.json.j2` | needed | `organize` to `usr/share/sonic/templates/` |
| L3 database | `files/90-sonic.conf`, `files/update_chassisdb_config`, `flush_unused_database` | needed | `organize` |


Apart from `Dockerfile.j2`, the `rules/*.mk` files are also the source of truth 
for what each container pulls in. For docker-database,
`$(DOCKER_DATABASE)_DEPENDENT_PACKAGES`, `$(DOCKER_DATABASE)_PYTHON_WHEELS`,
and the inherited `$(DOCKER_CONFIG_ENGINE_RESOLUTE)_*` variables together
define the full dependency set. Read them all.

---

## 4. Phase 2 — Author `rockcraft.yaml`

### 4.1 Header & services

```yaml
name: docker-database
summary: SONiC database container
description: A Chiselled rock for SONiC database container
version: "1.0.0"

base: bare
build-base: ubuntu@26.04
license: Apache-2.0

platforms:
  amd64:

services:
  rsyslogd:
    command: /usr/sbin/rsyslogd -n -iNONE
    override: replace
    startup: enabled
  init:
    command: docker-database-init.sh
    override: replace
    startup: enabled
    on-success: ignore
  redis:
    command: bash -c "{ [[ -s /var/lib/redis/dump.rdb ]] || rm -f /var/lib/redis/dump.rdb; } && mkdir -p /var/lib/redis && exec /usr/bin/redis-server /etc/redis/redis.conf --bind 127.0.0.1 --port 6379 --unixsocket /var/run/redis/redis.sock --pidfile /var/run/redis/redis.pid --dir /var/lib/redis"
    override: replace
  flushdb:
    command: bash -c "sleep 300 && /usr/local/bin/flush_unused_database"
    override: replace
    on-success: ignore
    on-failure: ignore
```

These services are ported from `supervisord.conf.j2`. The changes made:

- Each supervisord `program` becomes a pebble `service` with `override:
  replace`.
- **`rsyslogd`** and **`init`** get `startup: enabled` so they auto-start
  with the container. **`redis`** and **`flushdb`** do not — `init` starts
  them explicitly via `pebble start` after rendering `database_config.json`.
- **`init`** gets `on-success: ignore` so pebble doesn't restart it after
  the one-shot exits. **`flushdb`** gets both `on-success` and `on-failure`
  ignored (best-effort cleanup).
- The `redis` command gains a `bash -c` preamble that cleans a stale
  `dump.rdb` and ensures the data dir exists before exec'ing `redis-server`.
  Under supervisord this was handled by the init script.

### 4.2 The `parts` — what goes where

Rockcraft forbids mixing chisel slices and full packages in the same
`stage-packages` list, so packages without chisel slices go in a separate
part. Python wheels go in a dedicated `python` plugin part. The manifest
has three parts:

#### 4.2.1 `install-unchiselled-packages` — full packages (temporary)

```yaml
parts:
  install-unchiselled-packages:
    plugin: nil
    stage-packages:
      - rsyslog
      - rsyslog-relp
      - libpython3.14
      - libboost-serialization1.83.0
      - libxxhash0
```

`plugin: nil` just stages packages without building anything. These are
packages for which no chisel slice exists yet. `libpython3.14`,
`libboost-serialization1.83.0`, and `libxxhash0` were discovered as missing
shared libraries at runtime — the full Ubuntu base image in the Dockerfile
path provided them transitively.

This part is temporary, due to chose packages are not chiselled yet. 
The ultimate goal is to chisel all of these packages and
move their slices into the `stage-packages` list of the `setup-database`
part (section 4.2.4), so `install-unchiselled-packages` disappears
entirely.

#### 4.2.2 `setup-database` — chisel slices + dump plugin + override-build

```yaml
  setup-database:
    plugin: dump
    source: .
    override-build: |
        craftctl default

        # Install SONiC debs
        dpkg -x debs/socat_1.8.1.1-1_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/libswsscommon_1.0.0_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/libyang3_3.13.6-1ubuntu0.1_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/python3-libyang_3.1.0-1_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/python3-swsscommon_1.0.0_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/sonic-db-cli_1.0.0_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/sonic-eventd_1.0.0-0_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/libdashapi_1.0.0_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/libnl-3-200_3.12.0-2_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/libnl-route-3-200_3.12.0-2_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/libnl-genl-3-200_3.12.0-2_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/libnl-nf-3-200_3.12.0-2_amd64.deb ${CRAFT_PART_INSTALL}
        dpkg -x debs/libnl-cli-3-200_3.12.0-2_amd64.deb ${CRAFT_PART_INSTALL}

        # Clean up deb/wheel source files from install tree
        rm -rf ${CRAFT_PART_INSTALL}/debs ${CRAFT_PART_INSTALL}/python-wheels ${CRAFT_PART_INSTALL}/python-debs
```

- `plugin: dump` with `source: .` pulls the entire container directory
  (`dockers/docker-database/`) into the build. The `debs/`, `files/`,
  `python-wheels/` subdirectories are staged there by `build_rocks.sh`
  before `rockcraft pack` runs — they are not in git (they're in
  `.gitignore`).
- **SONiC debs use `dpkg -x`, not `dpkg -i`.** `base: bare` has no dpkg
  database or postinst machinery; we just extract files into
  `${CRAFT_PART_INSTALL}`. This is why packages that need a postinst to
  create users (like `redis-server`) must come through a chisel slice that
  includes the user metadata, not through `dpkg -x`.
- **deb filenames are hardcoded with versions.** When a SONiC package
  version changes, the filename in `rockcraft.yaml` must be updated. Using
  globs (`debs/socat_*.deb`) would avoid this but is not done here.
- The `rm -rf` keeps deb/wheel source blobs out of the primed image. Python
  wheels are installed by the separate `install-python` part (section 4.2.6).

#### 4.2.3 `organize` — map source paths to target paths

```yaml
    organize:
      database_config.json.j2: usr/share/sonic/templates/database_config.json.j2
      database_global.json.j2: usr/share/sonic/templates/database_global.json.j2
      multi_database_config.json.j2: usr/share/sonic/templates/multi_database_config.json.j2
      files/syslog-layer.yaml: usr/share/sonic/templates/
      docker-database-init.sh: usr/local/bin/docker-database-init.sh
      files/container_startup.py: usr/share/sonic/scripts/container_startup.py
      files/readiness_probe.sh: usr/bin/readiness_probe.sh
      files/swss_vars.j2: usr/share/sonic/templates/swss_vars.j2
      files/90-sonic.conf: usr/lib/sysctl.d/90-sonic.conf
      files/update_chassisdb_config: usr/local/bin/update_chassisdb_config
      flush_unused_database: usr/local/bin/flush_unused_database
```

`organize` is Rockcraft's file-relocation mechanism: after `dump` places
files at their source-relative paths, `organize` moves them to their final
on-disk paths inside the rock. Paths must match what SONiC scripts expect at
runtime.

#### 4.2.4 `stage` and `stage-packages` (chisel slices)

```yaml
    stage:
      - etc/
      - home/
      - lib
      - lib64
      - root/
      - var/
      - usr/
      - -usr/share/doc
      - -usr/share/doc-base
      - -usr/share/man
    stage-packages:
      - base-files_release-info
      - base-files_home
      - base-files_tmp
      - base-passwd_data
      - bash_bins
      - procps_bins
      - coreutils_bins
      - gawk_bins
      - redis-server_bins
      - iproute2_bins
      - python3.14_standard
      - libuuid1_libs
      - libhiredis1.1.0_libs
      - libzmq5_libs
```

- **`stage`** is a filter list: include these top-level dirs, but exclude
  (`-` prefix) `usr/share/doc`, `usr/share/doc-base`, `usr/share/man` to
  keep the image lean.
- **`stage-packages`** is the chisel-slice list. Each `<pkg>_<slice>` pulls
  only that slice's files. `base-passwd_data` provides `/etc/passwd` and
  `/etc/group`; `bash_bins` provides `/usr/bin/bash`; `redis-server_bins`
  provides the redis binary and its user metadata; `python3.14_standard`
  provides the Python stdlib.

To find the right slice names, browse the
[ubuntu chisel releases](https://github.com/canonical/chisel-releases)
for the `ubuntu-26.04` slice definitions. Each package's `sdf.yaml` lists
its slices and which files each slice contains.

#### 4.2.5 `override-prime` — final fixups

```yaml
    override-prime: |
      craftctl default

      # Make update script executable
      chmod +x usr/local/bin/update_chassisdb_config

      # Copy rsyslog config: this must not be done in the organize step.
      # Otherwise our rsyslog.conf will be overwritten by stage-package
      # rsyslog's default config.
      cp ${CRAFT_PROJECT_DIR}/files/rsyslog.conf etc/rsyslog.conf

      # Configure redis settings (same sed as Dockerfile.j2)
      sed -ri 's/^# save ""$/save ""/g; s/^daemonize yes$/daemonize no/; s/^logfile .*$/logfile ""/; s/^# syslog-enabled no$/syslog-enabled no/; s/^# unixsocket/unixsocket/; s/redis-server.sock/redis.sock/g; s/^client-output-buffer-limit pubsub [0-9]+mb [0-9]+mb [0-9]+/client-output-buffer-limit pubsub 0 0 0/; s/^notify-keyspace-events ""$/notify-keyspace-events AKE/; s/^databases [0-9]+$/databases 100/' etc/redis/redis.conf

      # Copy manifest to root
      cp ${CRAFT_PROJECT_DIR}/manifest.json .
```

`override-prime` runs after `stage` and is the last chance to mutate the
primed rootfs.

- **`chmod +x`** on scripts that lost their exec bit during `dump`.
- **`rsyslog.conf` must be copied in `override-prime`, not `organize`.** The
  `rsyslog` full package ships its own `/etc/rsyslog.conf`; if you put the
  SONiC version in via `organize`, the stage-package's default overwrites
  it. `override-prime` runs later, so the SONiC version wins.
  `${CRAFT_PROJECT_DIR}/files/rsyslog.conf` resolves to
  `dockers/docker-database/files/rsyslog.conf` — a file staged into the
  build context by `build_rocks.sh` (not in git). The full chain:
  `dockers/docker-base-resolute/etc/rsyslog.conf` → (build system via
  `SONIC_COPY_FILES`) → `target/files/resolute/rsyslog.conf` →
  (`build_rocks.sh`) → `dockers/docker-database/files/rsyslog.conf` →
  (`override-prime`) → `/etc/rsyslog.conf` in the rock.
- **`sed` on `redis.conf`** mirrors the `sed` in `Dockerfile.j2` — keep them
  in sync.
- **`manifest.json`** is copied to the rock root for SONiC's image
  introspection.

#### 4.2.6 `install-python` — Python wheels and pip packages

```yaml
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
```

This part uses Rockcraft's `python` plugin, which creates a virtual
environment and installs the listed packages. The SONiC wheels come from
`python-wheels/` (staged by `build_rocks.sh`); `jinjanator`, `click`,
`pyangbind`, `lxml` are pulled from PyPI. `python3-venv` is needed for the
venv creation.

The `python` plugin handles the Python path, the `python3` symlink, and
console-script placement automatically — which is why the previous
`override-prime` manual steps (`ln -sf python3.14 python3`,
`mv .../dist-packages/bin/* usr/bin/`) are no longer needed.

---

## 5. Phase 3 — Adapt the Init Script for Coexistence

The existing `docker-database-init.sh` is modified in-place rather than
duplicated into a separate `rock-database-init.sh`. 
A single boolean branch at the top diverges only at the
three points where supervisord and pebble actually differ.

### 5.1 The detection preamble

```bash
# Detect whether pebble is the process manager (rock/rockcraft path) or
# supervisord is (docker path). Branch only at the divergence points below.
USE_PEBBLE=false
if pgrep -x pebble > /dev/null 2>&1; then
    USE_PEBBLE=true
    LAYER_FILE="/usr/share/sonic/templates/syslog-layer.yaml"
    pebble add syslog-layer --combine $LAYER_FILE
    pebble replan
fi
```

- `pgrep -x pebble` detects whether pebble is the process manager. In the
  rock, pebble is the entrypoint, so this is true; in the Dockerfile
  container, supervisord is, so this is false.
- The syslog layer is added to pebble dynamically at init time via
  `pebble add syslog-layer --combine` then `pebble replan`. `--combine`
  merges with existing layers rather than replacing them.

### 5.2 The three divergence points

The shared logic (interface detection, BMP_DB_PORT, `database_config.json`
rendering via `jinjanate`, chassisdb config manipulation) runs unchanged.
The script only branches at three points:

**Divergence 1 — chassisdb branch (supervisord config generation):**
```bash
if [[ "$DATABASE_TYPE" == "chassisdb" ]]; then
    ...
    update_chassisdb_config -j $db_cfg_file_tmp -k -p $chassis_db_port
    if [[ "$USE_PEBBLE" != "true" ]]; then
        # Set protected mode based on the hostname
        additional_data_json=$(jq -c '{...}' "$db_cfg_file_tmp")
        # generate all redis server supervisord configuration file
        sonic-cfggen -j $db_cfg_file_tmp -a "$additional_data_json" \
        -t .../supervisord.conf.j2,/etc/supervisor/conf.d/supervisord.conf \
        -t .../critical_processes.j2,/etc/supervisor/critical_processes
        rm $db_cfg_file_tmp
        chown -R redis:redis $VAR_LIB_REDIS_CHASSIS_DIR
        chown -R redis:redis $REDIS_DIR
        exec /usr/local/bin/supervisord
    fi
    rm $db_cfg_file_tmp
    exit 0
fi
```
For the rock, the chassisdb branch is a no-op (`exit 0`) — multi-ASIC
chassis dynamic instance generation is out of scope.

**Divergence 2 — non-chassis supervisord config generation:**
```bash
if [[ "$USE_PEBBLE" != "true" ]]; then
    # Set protected mode based on the hostname
    additional_data_json=$(jq -c '{...}' "$db_cfg_file_tmp")
    if [ -f "$chassisdb_config" ] && [[ "$start_chassis_db" != "1" ]]; then
        additional_data_json=$(jq -c '{...}' "$db_cfg_file_tmp")
    fi
    sonic-cfggen -j "$db_cfg_file_tmp" -a "$additional_data_json" \
    -t .../supervisord.conf.j2,/etc/supervisor/conf.d/supervisord.conf \
    -t .../critical_processes.j2,/etc/supervisor/critical_processes
fi
```
The `is_protected_mode`/`additional_data_json` jq logic exists *only* to
feed `supervisord.conf.j2`; the rock doesn't render that template, so the
whole block is skipped under pebble.

**Divergence 3 — chown/exec vs. pebble start:**
```bash
    if [[ "$USE_PEBBLE" != "true" ]]; then
        chown -R redis:redis /var/lib/$inst
    fi
done

if [[ "$USE_PEBBLE" == "true" ]]; then
    pebble start redis
    pebble start flushdb
else
    chown -R redis:redis $REDIS_DIR
    REDIS_BMP_DIR="/var/lib/redis_bmp"
    if [[ -d $REDIS_BMP_DIR ]]; then
        chown -R redis:redis $REDIS_BMP_DIR
    fi

    exec /usr/local/bin/supervisord
fi
```
- Under supervisord, `chown -R redis:redis` is needed because supervisord
  launches redis as the `redis` user. Under pebble, the `redis` service runs
  as root (the rock's default) so the chowns are skipped.
- Under pebble, instead of `exec supervisord`, the script issues
  `pebble start redis` and `pebble start flushdb`. These services don't have
  `startup: enabled` (only `rsyslogd` and `init` do), so they don't
  auto-start; the init script starts them after `database_config.json` is
  rendered. This ordering is critical: the config must exist before redis
  starts.

---

## 6. Phase 4 — Wire the Build System

### 6.1 `rules/scripts.mk` — register shared files

```makefile
ifeq ($(BLDENV), resolute)
    RSYSLOG_CONF = rsyslog.conf
    $(RSYSLOG_CONF)_PATH = dockers/docker-base-resolute/etc/

    RSYSLOG_PEBBLE_LAYER = syslog-layer.yaml
    $(RSYSLOG_PEBBLE_LAYER)_PATH = files/rsyslog/
endif
```
appended to `SONIC_COPY_FILES`:
```makefile
                    $(RSYSLOG_CONF) \
                    $(RSYSLOG_PEBBLE_LAYER) \
```

- The `ifeq ($(BLDENV), resolute)` guard ensures these variables only exist
  for the Resolute build environment.
- `$(RSYSLOG_CONF)_PATH` points to the *existing* `rsyslog.conf` (the SONiC
  custom config with omrelp forwarding) — no new file is created for it.

### 6.2 `rules/scripts.dep` — disable caching

```makefile
$(RSYSLOG_CONF)_CACHE_MODE  := none
$(RSYSLOG_PEBBLE_LAYER)_CACHE_MODE := none
```
`CACHE_MODE=none` tells the build system not to cache these files between
builds. They are small and may change, so always re-copy.

### 6.3 `rules/docker-config-engine-resolute.mk` — stage into the docker config engine

```makefile
$(DOCKER_CONFIG_ENGINE_RESOLUTE)_FILES += $(RSYSLOG_CONF)
$(DOCKER_CONFIG_ENGINE_RESOLUTE)_FILES += $(RSYSLOG_PEBBLE_LAYER)
```
This adds the two files to the docker-config-engine-resolute container's
file list, so they're staged into *that* container's build context too (the
Dockerfile path still uses them for its own rsyslog setup). This keeps both
paths consistent.

### 6.4 `files/rsyslog/syslog-layer.yaml` — the pebble syslog layer

```yaml
log-targets:
  host-syslog:
    override: replace
    type: syslog
    location: udp://127.0.0.1:514/
    services: [all]
```
This is a Pebble *log-targets* layer: it tells pebble to forward all
services' logs via syslog to `udp://127.0.0.1:514/` (the host's rsyslog,
which the SONiC host config listens on). It is loaded at init time by
`pebble add syslog-layer --combine` (Phase 3). This file is shared by all rock
containers.

### 6.5 `files/build_templates/docker_image_ctl.j2` — readiness checks

Two readiness checks are modified to accept *either* pebble or supervisord:

```bash
# database container check (line 285):
until [[ ($(docker exec -i database$DEV pgrep -x -c pebble) -gt 0 || $(docker exec -i database$DEV pgrep -x -c supervisord) -gt 0) && ($($SONIC_DB_CLI PING | grep -c PONG) -gt 0) && ...

# chassisdb container check (line 357):
until [[ ($(docker exec -i ${DOCKERNAME} pgrep -x -c supervisord) -gt 0 || $(docker exec -i ${DOCKERNAME} pgrep -x -c pebble) -gt 0) && ...
```
The host-side `docker_image_ctl.j2` template generates the container
start/wait script. Without this change, a rock-based container (which runs
pebble, not supervisord) would fail the readiness wait and the host would
never consider the database "up."

When you migrate your own container, check every `docker_image_ctl.j2`
readiness block that names your container and add the pebble OR.

### 6.6 `build_rocks.sh` — the standalone build orchestrator

```bash
#!/bin/bash

# Finish `make SONIC_BUILD_JOBS=4 target/sonic-vs.img.gz` first
rocklist=(
    "dockers/docker-database"
)

set -x
set -e

for rockitem in "${rocklist[@]}"
do
    mkdir -p $rockitem/debs $rockitem/files $rockitem/python-wheels

    cp target/debs/resolute/*.deb            $rockitem/debs/
    cp -r target/files/resolute/*            $rockitem/files/
    cp target/python-wheels/resolute/*.whl   $rockitem/python-wheels/
    echo "export IMAGE_VERSION=$(git rev-parse --abbrev-ref HEAD)-$(git rev-parse HEAD)" > $rockitem/envs

    pushd $rockitem

    rockname=$(basename $rockitem)
    rockfullname="${rockname}_1.0.0_amd64.rock"
    rockcraft clean
    rockcraft pack
    sudo rockcraft.skopeo --insecure-policy copy oci-archive:$rockfullname docker-daemon:$rockname:latest
    rm -r ./debs/ ./files/ ./python-wheels/ envs ${rockfullname}

    popd

    pushd target
    docker save $rockname:latest  | pigz -c  >${rockname}.gz
    popd

    docker rmi -f $rockname:latest
done
```

Walkthrough:

1. **Stage build artifacts** into each container's `debs/`, `files/`,
   `python-wheels/` dirs — the dirs `rockcraft.yaml`'s `source: .` picks up.
   They are gitignored.
2. **Generate `envs`** with `IMAGE_VERSION` = branch name + commit hash. This
   file is currently vestigial — it was sourced by the init script in an
   earlier revision but is no longer consumed.
3. **`rockcraft clean` + `rockcraft pack`** builds the `.rock` OCI archive.
4. **`rockcraft.skopeo copy`** converts the `.rock` into a Docker daemon
   image tagged `<rockname>:latest`. `--insecure-policy` is needed because
   the default skopeo policy doesn't know about rocks.
5. **Cleanup** the staged `debs/files/python-wheels/envs` and the `.rock`
   (they're regenerated each run).
6. **`docker save | pigz`** produces `target/<rockname>.gz` — the same
   format the Makefile produces for Dockerfile containers.
7. **`docker rmi -f`** removes the local image to keep the daemon clean.

`build_rocks.sh` runs on the host after `make`, not integrated into the
Makefile graph. `make` builds
inside a `sonic-slave-resolute` container that doesn't have rockcraft.
Integrating rockcraft into the Makefile graph would require restructuring
the slave container, so we keep the build process a manual two-step: 
`make ... && ./build_rocks.sh`.

### 6.7 `.gitignore` — rockcraft build artifacts

```gitignore
# Copied files for rockcraft build
dockers/*/debs/
dockers/*/files/
dockers/*/python-wheels/
dockers/*/envs
dockers/*/*.rock
```
The `dockers/*/` patterns cover the staged `debs/`, `files/`,
`python-wheels/`, `envs` and the built `.rock` for every container dir, so
adding a new container to `build_rocks.sh`'s `rocklist` needs no
`.gitignore` edit.

---

## 7. Phase 5 — Build and Verify

### 7.1 Build steps

```bash
# 1. Standard make (produces target/debs/resolute/, target/files/resolute/,
#    target/python-wheels/resolute/)
make SONIC_BUILD_JOBS=4 target/sonic-vs.img.gz

# 2. Build rocks (host-side, needs LXD + rockcraft + docker)
./build_rocks.sh

# 3. Re-run make to package the rock container images into the final
#    sonic-vs.img.gz
make SONIC_BUILD_JOBS=4 target/sonic-vs.img.gz
```
`build_rocks.sh` produces `target/docker-database.gz`. The final re-make
packages it (and any other rock container images) into the SONiC image.

### 7.2 Verification checklist

1. `make target/sonic-vs.img.gz` still succeeds — the Dockerfile path is
   unmodified.
2. `build_rocks.sh` completes and `target/docker-database.gz` exists.
3. The final re-make packages the rock image into `sonic-vs.img.gz`.
4. Load the image and start the container; `redis-cli PING` returns `PONG`.
5. `pebble logs` (or `docker logs`) shows no `ImportError` or
   `error while loading shared libraries` messages.
6. `docker_image_ctl.j2` correctly detects the pebble-based container
   (the readiness wait completes).

---

## 8. Pitfalls

### 8.1 Hardcoded deb filenames

The `dpkg -x debs/libyang3_3.13.6-1ubuntu0.1_amd64.deb ...` lines embed
versions. When a SONiC package version bumps, the rock build breaks until
you update the filename. Using globs (`debs/libyang3_*.deb`) avoids this.

### 8.2 The `redis` user and `chown -R redis:redis`

Under supervisord, redis runs as the `redis` user, so the init script
`chown -R redis:redis` the data dirs. Under pebble in the chiselled rock,
the `redis` service runs as root and those chowns are skipped. The `redis`
user/group themselves come from the `redis-server_bins` (and
`base-passwd_data`) chisel slices, not from a manual `echo` in
`override-prime`. If your container runs a daemon as a non-root user,
verify the user comes from a slice before relying on it.

### 8.3 `rsyslog.conf` copy timing

As explained in Phase 2, `rsyslog.conf` must be copied in `override-prime`,
not `organize` — the `rsyslog` stage-package's own `/etc/rsyslog.conf`
overwrites it during staging. The general rule: put any file that conflicts
with a stage-package's file in `override-prime`. The symptom of getting this
wrong is "my rsyslog config is ignored."

### 8.4 Multi-ASIC / VoQ scope

The docker-database rock's static pebble services only start one Redis
instance. The Dockerfile path, by rendering `supervisord.conf.j2` per
instance, supports multi-ASIC and VoQ chassis. Supporting multi-ASIC in the
rock would require dynamic pebble layer generation: the init script would
generate a pebble layer per instance and `pebble add` + `pebble replan`.
That is a fundamentally different architecture from the static services
defined in `rockcraft.yaml`, and is future work beyond this case study.

### 8.5 `rockcraft.skopeo`, not `skopeo`

Use the `rockcraft.skopeo` binary shipped with the rockcraft snap. Bare
`skopeo` may lack the policy support for `.rock` OCI archives. The
`--insecure-policy` flag is required.

### 8.6 Build graph integration is intentionally absent

`build_rocks.sh` runs on the host after `make`. Folding rockcraft into
`slave.mk` / `rules/*.mk` would require reworking the `sonic-slave`
container to include rockcraft. That's a separate, larger effort.

### 8.7 Environment variables: Dockerfile `ENV` vs rockcraft `services`

Dockerfile's `ENV DEBIAN_FRONTEND=noninteractive`, `ENV IMAGENAME=...`,
and `ENV DISTRO=...` are build-time / build-graph variables. They are set via `ENV` in the 
Dockerfile and propagated as container-wide environment variables, but no runtime script in 
these containers actually reads them. 
`DEBIAN_FRONTEND` is an apt-get build-time flag; `IMAGENAME` and `DISTRO` are Docker 
build-graph variables injected via `--build-arg`.


---

## 9. Appendix — File Inventory

### New files

| Path | Purpose |
|---|---|
| `dockers/docker-database/rockcraft.yaml` | The rock manifest (Phase 2) |
| `files/rsyslog/syslog-layer.yaml` | Shared pebble syslog layer (Phase 4.4) |
| `build_rocks.sh` | Standalone rock build orchestrator (Phase 4.6) |

### Modified files

| Path | Change |
|---|---|
| `dockers/docker-database/docker-database-init.sh` | `USE_PEBBLE` branch (Phase 3) |
| `rules/scripts.mk` | `RSYSLOG_CONF`, `RSYSLOG_PEBBLE_LAYER` vars + `SONIC_COPY_FILES` (Phase 4.1) |
| `rules/scripts.dep` | `CACHE_MODE=none` for the two new files (Phase 4.2) |
| `rules/docker-config-engine-resolute.mk` | Add the two files to `_FILES` (Phase 4.3) |
| `files/build_templates/docker_image_ctl.j2` | pebble OR supervisord readiness (Phase 4.5) |
| `.gitignore` | rockcraft build artifacts (Phase 4.7) |

### Untouched (coexistence)

| Path | Why untouched |
|---|---|
| `dockers/docker-database/Dockerfile.j2` | Dockerfile path must keep working |
| `dockers/docker-database/supervisord.conf.j2` | supervisord-specific |
| `dockers/docker-database/critical_processes.j2` | supervisord-specific |
| `dockers/docker-base-resolute/etc/rsyslog.conf` | Referenced by `$(RSYSLOG_CONF)_PATH`, not modified |

---
