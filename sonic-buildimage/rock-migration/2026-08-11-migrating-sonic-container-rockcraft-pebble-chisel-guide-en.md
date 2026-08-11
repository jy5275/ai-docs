# Migrating a SONiC Container from Dockerfile + supervisord to Rockcraft + Pebble + Chisel

**A docker-database Case Study on Ubuntu Resolute (26.04)**

**Date:** 2026-08-11
**Source branch:** `202605_resolute_rock`
**Reference commits:**
- `6853735e9` — build: add rockcraft build infrastructure and pebble/supervisord coexistence
- `d319c706f` — build: migrate docker-database to rockcraft+pebble

---

## 1. Introduction

### 1.1 What this guide is

This is a hands-on migration guide. It walks through the `docker-database`
container's migration from a Dockerfile + supervisord packaging to a Rockcraft
manifest + Pebble services + Chisel slices rock, step by step, using the real
files committed on the `202605_resolute_rock` branch as the worked example.

The goal is not to document docker-database itself, but to teach the
**method** so you can apply it to your own SONiC container.

### 1.2 Who this is for

Software and network engineers who:

- Are comfortable with SONiC, container networking, and the existing
  Dockerfile-based build graph (`rules/*.mk`, `slave.mk`, `Dockerfile.j2`).
- Already understand the *concepts* behind Rockcraft, Pebble, and Chisel
  (what a rock is, what a pebble layer/service is, what a chisel slice is)
  and now want a concrete, end-to-end recipe.
- Are new to the Canonical tooling ecosystem and need the practical wiring:
  which file goes where, which Make variables to touch, what breaks at
  runtime.

### 1.3 The two commits and what they split

The migration was delivered as two commits that together establish the
pattern every later container migration on this branch follows:

| Commit | Scope | Files touched |
|--------|-------|---------------|
| `6853735e9` | **Build infrastructure** — shared plumbing that all rock containers reuse | `files/rsyslog/syslog-layer.yaml` (new), `rules/scripts.mk`, `rules/scripts.dep`, `rules/docker-config-engine-resolute.mk`, `files/build_templates/docker_image_ctl.j2`, `.gitignore` |
| `d319c706f` | **docker-database itself** — the container-specific rock | `dockers/docker-database/rockcraft.yaml` (new), `dockers/docker-database/docker-database-init.sh` (modified), `build_rocks.sh` (new) |

The split is intentional: commit 1 is reusable by every subsequent container;
commit 2 is the per-container work. When you migrate your own container you
will mostly produce a commit that looks like commit 2, and only touch the
commit-1 plumbing if your container needs a *new* shared file.

### 1.4 Note on prior AI-generated design docs

Two AI-generated documents (`2026-07-16-rockcraft-pebble-docker-database-resolute-design-en.md`
and its plan sibling) were produced *before* the implementation. The actual
committed code diverges from them in several places. Where they conflict,
**this guide follows the source code**. The most important divergences:

1. **Unified init script, not a copy.** The design doc proposed a separate
   `rock-database-init.sh`. The code instead modified the *existing*
   `docker-database-init.sh` with a `USE_PEBBLE` flag so one script serves
   both the Dockerfile and the Rockcraft path. (See Phase 3.)
2. **No `SUPERVISOR_PROC_EXIT_LISTENER_SCRIPT`.** The plan added this
   variable to `rules/scripts.mk`; it was never committed. Only
   `RSYSLOG_CONF` and `RSYSLOG_PEBBLE_LAYER` were added.
3. **Stage-packages contents.** The design doc listed
   `libpython3.14-stdlib` / `libpython3.14-minimal` as separate full
   packages; the code puts only `libpython3.14` (plus
   `libboost-serialization1.83.0`, `libxxhash0`) in the full-package part,
   and relies on the `python3.14_standard` chisel slice for the stdlib.
4. **No manual `redis` user creation in `override-prime`.** The design doc
   described `echo 'redis:x:999...'` lines; the committed `override-prime`
   does not contain them. The `redis` user/group come from the
   `redis-server_bins` chisel slice.

Keep these in mind if you cross-reference the earlier docs.

### 1.5 Scope of the docker-database migration

- **VS / single-ASIC only.** The rock starts a single static Redis instance.
  Multi-ASIC and VoQ chassis dynamic-instance generation (which the
  Dockerfile path does by rendering `supervisord.conf.j2` per instance) is
  **not** reproduced by the rock's static Pebble services. This is an
  accepted, documented scope limit.
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
- **pigz** for the final gzip.
- A completed `make target/sonic-vs.img.gz` run — the rock build *consumes*
  `target/debs/resolute/`, `target/files/resolute/`, and
  `target/python-wheels/resolute/`. Rockcraft is not integrated into the
  Makefile build graph; `build_rocks.sh` is a standalone, host-side script
  run manually after `make` finishes.

### 2.2 Chiselled rock mental model (`base: bare`)

A standard rock uses `base: ubuntu@24.04` and gets a full Ubuntu filesystem.
The docker-database rock instead uses:

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

This is the key trade-off of the chisel approach: the resulting image is
small and contains no surprises, but you are responsible for discovering and
listing every transitive runtime dependency that the Dockerfile got "for
free" from the base image. Phase 5 documents the libraries that were found
missing at runtime and had to be added.

> **Why not `base: ubuntu@26.04`?** Later container migrations on this
> branch (docker-eventd, docker-router-advertiser, docker-sonic-mgmt-framework)
> adopted the simpler full-base approach. This guide covers the chisel
> approach used by docker-database, which was the pioneering migration.
> If your container has a large runtime footprint and image size is not a
> hard constraint, the full-base approach is easier — but the layer-flattening
> analysis in Phase 1 applies to both.

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

This is why the migration reads as "add a parallel path" rather than
"replace the Dockerfile."

---

## 3. Phase 1 — Analyze the Docker Layer Chain

This is the single most important analysis step. Rockcraft `base: bare` has
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

Here is the flattened map that produced the committed `rockcraft.yaml`.
Use this as a template for your own container's analysis.

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
| L2 config-engine | `pyangbind==0.8.7` | needed | `pip3 install` in `override-build` |
| L2 config-engine | `build-essential`, `python3-dev`, `apt-utils`, `python3-cffi` | drop (build-only / unused at runtime) | — |
| L2 config-engine | `libswsscommon`, `libyang3`, `python3-libyang`, `python3-swsscommon`, `sonic-db-cli`, `sonic-eventd` (SONiC debs) | needed | `dpkg -x` in `override-build` |
| L2 config-engine | `sonic-supervisord-utilities-rs` | drop (supervisord) | — |
| L2 config-engine | wheels: `sonic_py_common`, `sonic_yang_mgmt`, `sonic_yang_models`, `sonic_containercfgd`, `sonic_config_engine` | needed | `pip3 install` in `override-build` |
| L2 config-engine | `sonic_supervisord_utilities` (wheel) | drop (supervisord) | — |
| L2 config-engine | `files/swss_vars.j2`, `files/readiness_probe.sh`, `files/container_startup.py` | needed | `organize` |
| L2 config-engine | `rsyslog.conf`, `syslog-layer.yaml` (new) | needed | `syslog-layer.yaml` via `organize`; `rsyslog.conf` via `override-prime` |
| L3 database | `redis-server` | needed | `redis-server_bins` slice |
| L3 database | `redis-tools` | dedup with L1 | (covered by slices) |
| L3 database | `click` (pip) | needed | `pip3 install` in `override-build` |
| L3 database | `libdashapi` (SONiC deb) | needed | `dpkg -x` in `override-build` |
| L3 database | `libswsscommon`, `sonic-db-cli` (SONiC debs) | dedup with L2 | single `dpkg -x` entry |
| L3 database | `supervisord.conf.j2`, `critical_processes.j2` | drop (supervisord) | — |
| L3 database | `database_config.json.j2`, `database_global.json.j2`, `multi_database_config.json.j2` | needed | `organize` to `usr/share/sonic/templates/` |
| L3 database | `files/90-sonic.conf`, `files/update_chassisdb_config`, `flush_unused_database` | needed | `organize` |

**Output of this phase:** the table above. Everything in the "Rockcraft
landing" column becomes a line in `rockcraft.yaml`. If you cannot fill a row,
you are not ready to write the manifest yet — go find where that dependency
is declared.

> **Tip:** the `rules/*.mk` files are the source of truth for what each
> container pulls in, *not* just the `Dockerfile.j2`. For docker-database,
> `$(DOCKER_DATABASE)_DEPENDENT_PACKAGES`, `$(DOCKER_DATABASE)_PYTHON_WHEELS`,
> and the inherited `$(DOCKER_CONFIG_ENGINE_RESOLUTE)_*` variables together
> define the full dependency set. Read them all.

---

## 4. Phase 2 — Author `rockcraft.yaml`

With the map from Phase 1, write `dockers/docker-database/rockcraft.yaml`.
This is the committed file in its entirety; the subsections explain each
block's rationale.

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
    environment:
      DEBIAN_FRONTEND: "noninteractive"
      IMAGENAME: "docker-database"
      DISTRO: "resolute"
  redis:
    command: bash -c "{ [[ -s /var/lib/redis/dump.rdb ]] || rm -f /var/lib/redis/dump.rdb; } && mkdir -p /var/lib/redis && exec /usr/bin/redis-server /etc/redis/redis.conf --bind 127.0.0.1 --port 6379 --unixsocket /var/run/redis/redis.sock --pidfile /var/run/redis/redis.pid --dir /var/lib/redis"
    override: replace
    environment:
      DEBIAN_FRONTEND: "noninteractive"
      IMAGENAME: "docker-database"
      DISTRO: "resolute"
  flushdb:
    command: bash -c "sleep 300 && /usr/local/bin/flush_unused_database"
    override: replace
    on-success: ignore
    on-failure: ignore
    environment:
      DEBIAN_FRONTEND: "noninteractive"
      IMAGENAME: "docker-database"
      DISTRO: "resolute"
```

Design notes:

- **`rsyslogd`** runs in the foreground (`-n`) with no PID file (`-iNONE`)
  and starts on boot. This is the SONiC convention: every container forwards
  syslog to the host via rsyslog.
- **`init`** runs the (now-unified) `docker-database-init.sh`. It sets up the
  syslog pebble layer, renders `database_config.json`, then issues
  `pebble start redis` and `pebble start flushdb`. `on-success: ignore`
  means pebble won't restart it after it exits — init is a one-shot.
- **`redis`** is the single static Redis instance. The `bash -c` preamble
  cleans a stale `dump.rdb` and ensures the data dir exists before exec'ing
  `redis-server`. This command is the static, single-instance equivalent of
  what `supervisord.conf.j2` used to render dynamically per instance.
- **`flushdb`** sleeps 300s then runs `flush_unused_database`. Both
  `on-success` and `on-failure` are ignored — it's a best-effort cleanup.
- The `DISTRO: "resolute"` and `IMAGENAME` environment variables are what
  SONiC scripts (e.g. `container_startup.py`) read to behave correctly.
  This is a Resolute-specific value; on Noble it would be `"noble"`.

### 4.2 The two `parts` — why split, and what goes where

Rockcraft forbids mixing chisel slices and full apt packages in the same
`stage-packages` list. So the manifest has two parts:

#### 4.2.1 `install-unchiselled-packages` — full packages

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

`plugin: nil` means "just stage these packages, don't build anything."
These are packages for which either no chisel slice exists, or a full
package is simpler. `libpython3.14`, `libboost-serialization1.83.0`, and
`libxxhash0` were **discovered at runtime** (Phase 5) as missing shared
libraries and added here; they are not in the original Dockerfile's apt
list because the full Ubuntu base image provided them transitively.

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

        # Install python packages
        pip3 install --upgrade -t ${CRAFT_PART_INSTALL}/usr/lib/python3.14/dist-packages/ \
          ./python-wheels/sonic_py_common-1.0-py3-none-any.whl \
          ./python-wheels/sonic_yang_mgmt-1.0-py3-none-any.whl \
          ./python-wheels/sonic_yang_models-1.0-py3-none-any.whl \
          ./python-wheels/sonic_containercfgd-1.0-py3-none-any.whl \
          ./python-wheels/sonic_config_engine-1.0-py3-none-any.whl \
          jinjanator \
          click \
          pyangbind==0.8.7 \
          lxml

        # Clean up deb/wheel source files from install tree
        rm -rf ${CRAFT_PART_INSTALL}/debs ${CRAFT_PART_INSTALL}/python-wheels ${CRAFT_PART_INSTALL}/python-debs
```

Key points:

- `plugin: dump` with `source: .` pulls the entire container directory
  (`dockers/docker-database/`) into the build. The `debs/`, `files/`,
  `python-wheels/`, and `envs` subdirectories are **staged there by
  `build_rocks.sh`** before `rockcraft pack` runs — they are not in git
  (they're in `.gitignore`).
- **SONiC debs use `dpkg -x`, not `dpkg -i`.** `base: bare` has no dpkg
  database / postinst machinery; we just extract files into
  `${CRAFT_PART_INSTALL}`. This is why packages that need a postinst to
  create users (like `redis-server`) must come through a chisel slice that
  includes the user metadata, not through `dpkg -x`.
- **deb filenames are hardcoded with versions.** This is a known
  maintenance cost: when a SONiC package version changes, the filename in
  `rockcraft.yaml` must be updated. (Later migrations mitigate this with
  glob patterns like `debs/socat_*.deb` — see docker-eventd's `rockcraft.yaml`
  for the pattern. The docker-database commit predates that improvement.)
- **pip wheels install to `usr/lib/python3.14/dist-packages/`** (Resolute
  uses Python 3.14; Noble used 3.12). The `-t` flag targets that directory
  explicitly. `jinjanator`, `click`, `pyangbind`, `lxml` are pulled from PyPI
  by the build-base's pip.
- The final `rm -rf` keeps deb/wheel source blobs out of the primed image.

#### 4.2.3 `organize` — map source paths to target paths

```yaml
    organize:
      database_config.json.j2: usr/share/sonic/templates/database_config.json.j2
      database_global.json.j2: usr/share/sonic/templates/database_global.json.j2
      envs: usr/share/sonic/scripts/envs
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
files at their source-relative paths, `organize` moves them to their
final on-disk paths inside the rock. This replaces the many `COPY` /
`install` lines in the Dockerfile chain. Paths must match what SONiC scripts
expect at runtime (e.g. `/usr/share/sonic/templates/`, `/usr/local/bin/`).

Note `files/syslog-layer.yaml` here: the `files/` directory is *staged* by
`build_rocks.sh` (copied from `target/files/resolute/`), so `syslog-layer.yaml`
arrives via the shared `files/rsyslog/syslog-layer.yaml` registered in
`SONIC_COPY_FILES`. The `organize` line moves it to the templates dir.

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
  `/etc/group` (with `redis` and other users); `bash_bins` provides
  `/usr/bin/bash`; `redis-server_bins` provides the redis binary and its
  user metadata; `python3.14_standard` provides the Python stdlib. This is
  the chisel equivalent of the L1 apt list, minus what's dropped.

> **How to find the right slice names?** Browse the
> [ubuntu chisel releases](https://github.com/canonical/chisel-releases)
> for the `ubuntu-26.04` slice definitions. Each package's `sdf.yaml` lists
> its slices and which files each slice contains. The
> `chisel-releases` skill in this workspace can author/review slice
> definitions if you need a slice that doesn't exist yet.

#### 4.2.5 `override-prime` — final fixups

```yaml
    override-prime: |
      craftctl default

      # Create symlinks
      ln -sf /usr/bin/gawk usr/bin/awk
      ln -sf /usr/bin/python3.14 usr/bin/python3

      # Move python bins
      mv usr/lib/python3.14/dist-packages/bin/* usr/bin/

      # Make update script executable
      chmod +x usr/local/bin/update_chassisdb_config

      # Copy rsyslog config: this must not be done in the organize step.
      # Otherwise our rsyslog.conf will be overwritten by stage-package rsyslog's default config.
      cp ${CRAFT_PROJECT_DIR}/files/rsyslog.conf etc/rsyslog.conf

      # Configure redis settings (same sed as Dockerfile.j2)
      sed -ri 's/^# save ""$/save ""/g; s/^daemonize yes$/daemonize no/; s/^logfile .*$/logfile ""/; s/^# syslog-enabled no$/syslog-enabled no/; s/^# unixsocket/unixsocket/; s/redis-server.sock/redis.sock/g; s/^client-output-buffer-limit pubsub [0-9]+mb [0-9]+mb [0-9]+/client-output-buffer-limit pubsub 0 0 0/; s/^notify-keyspace-events ""$/notify-keyspace-events AKE/; s/^databases [0-9]+$/databases 100/' etc/redis/redis.conf

      # Copy manifest to root
      cp ${CRAFT_PROJECT_DIR}/manifest.json .
```

`override-prime` runs after `stage` and is the last chance to mutate the
primed rootfs. The committed fixups:

- **Symlinks** `awk`→`gawk` and `python3`→`python3.14`. With `base: bare`
  these symlinks don't exist until you create them.
- **`mv usr/lib/python3.14/dist-packages/bin/* usr/bin/`** — some pip wheels
  install console scripts under `.../dist-packages/bin/`; move them onto
  `PATH`.
- **`chmod +x`** on scripts that lost their exec bit during `dump`.
- **`rsyslog.conf` copy is in `override-prime`, not `organize`.** This is a
  subtle, important point: the `rsyslog` full package (staged by
  `install-unchiselled-packages`) ships its own `/etc/rsyslog.conf`. If you
  put the SONiC `rsyslog.conf` in via `organize`, the stage-package's
  default would overwrite it. Doing the copy in `override-prime` (which runs
  later) guarantees the SONiC version wins. `${CRAFT_PROJECT_DIR}` is the
  directory containing `rockcraft.yaml` — here `dockers/docker-database/` —
  so `${CRAFT_PROJECT_DIR}/files/rsyslog.conf` resolves to
  `dockers/docker-database/files/rsyslog.conf`. That file is **not** in git;
  it's staged into the build context by `build_rocks.sh`, which does
  `cp -r target/files/resolute/* $rockitem/files/`. The build system put it
  in `target/files/resolute/rsyslog.conf` because `RSYSLOG_CONF` is
  registered in `SONIC_COPY_FILES` with source path
  `dockers/docker-base-resolute/etc/` (see Phase 4.1). So the chain is:
  `dockers/docker-base-resolute/etc/rsyslog.conf` → (build system) →
  `target/files/resolute/rsyslog.conf` → (`build_rocks.sh`) →
  `dockers/docker-database/files/rsyslog.conf` → (`override-prime`) →
  `/etc/rsyslog.conf` in the rock.
- **`sed` on `redis.conf`** mirrors exactly the `sed` in the original
  `Dockerfile.j2`. It must be kept in sync if the Dockerfile's sed changes.
- **`manifest.json`** is copied to the rock root for SONiC's image
  introspection.

---

## 5. Phase 3 — Adapt the Init Script for Coexistence

The biggest decision in this migration: **modify the existing
`docker-database-init.sh` rather than create a `rock-database-init.sh`.**
The AI design doc proposed a separate file; the commit chose a unified
script. Here's why and how.

### 5.1 Why a unified script

A separate `rock-database-init.sh` would duplicate ~150 lines of
Resolute-specific logic (BMP_DB_PORT, multi-database detection, jinjanate
rendering, chassisdb branch) and the two copies would drift. Instead, the
committed approach adds a single boolean branch at the top and only
diverges at the three points where supervisord and pebble actually differ.

### 5.2 The detection preamble

```bash
# Detect whether pebble is the process manager (rock/rockcraft path) or
# supervisord is (docker path). Branch only at the divergence points below.
USE_PEBBLE=false
if pgrep -x pebble > /dev/null 2>&1; then
    USE_PEBBLE=true
    source /usr/share/sonic/scripts/envs
    LAYER_FILE="/usr/share/sonic/templates/syslog-layer.yaml"
    pebble add syslog-layer --combine $LAYER_FILE
    pebble replan
fi
```

- `pgrep -x pebble` detects whether pebble is PID 1's process manager. In
  the rock, pebble is the entrypoint, so this is true; in the Dockerfile
  container, supervisord is, so this is false.
- `source /usr/share/sonic/scripts/envs` loads `IMAGE_VERSION` (and any
  other env) generated by `build_rocks.sh` into the `envs` file. This
  replaces the env vars the Dockerfile path gets from the build graph.
- The syslog layer is added to pebble *dynamically* at init time via
  `pebble add syslog-layer --combine` then `pebble replan`. `--combine`
  merges with existing layers rather than replacing them. This is the
  SONiC pattern for per-container syslog forwarding to the host.

### 5.3 The three divergence points

The script then runs the shared logic (interface detection, BMP_DB_PORT,
`database_config.json` rendering via `jinjanate`, chassisdb config
manipulation) unchanged. It only branches at three points:

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
chassis dynamic instance generation is out of scope (Section 1.5).

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
- Under supervisord, the `chown -R redis:redis` calls are needed because
  supervisord launches redis as the `redis` user. Under pebble, the
  `redis` service runs as root (the rock's default) so the chowns are
  skipped — and indeed skipping them is required, since the `redis` user
  may not exist in the chiselled rootfs in a way that supports chown.
- Under pebble, instead of `exec supervisord`, the script issues
  `pebble start redis` and `pebble start flushdb`. The `redis` and `flushdb`
  services are defined in `rockcraft.yaml` with `startup: enabled` *not*
  set (only `rsyslogd` and `init` have `startup: enabled`), so they don't
  auto-start; the init script starts them after configuration is rendered.
  This ordering is critical: `database_config.json` must exist before
  redis starts.

### 5.4 What is *not* changed

The `mkdir -p /etc/supervisor/conf.d/` line is left in the script even on
the pebble path (it's harmless — an empty dir). This is a deliberate
minimal-edit choice: keep the diff small and the supervisord path provably
unaffected. When you migrate your own container, resist the urge to "clean
up" supervisord lines that are harmless; the goal is a *minimal,
backward-compatible* change.

---

## 6. Phase 4 — Wire the Build System

This phase corresponds to commit `6853735e9`. These are the shared changes
that every rock container benefits from.

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
  for the Resolute build environment — Noble and older branches are
  untouched.
- `SONIC_COPY_FILES` is the master list of files the build system stages
  into `target/files/<env>/`. By registering `rsyslog.conf` and
  `syslog-layer.yaml` here, `build_rocks.sh`'s `cp -r target/files/resolute/*
  $rockitem/files/` picks them up automatically.
- `$(RSYSLOG_CONF)_PATH = dockers/docker-base-resolute/etc/` points to the
  *existing* `rsyslog.conf` (the SONiC custom config with omrelp forwarding)
  — no new file is created for it. Only `syslog-layer.yaml` is new.

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
which the SONiC host config listens on). `override: replace` means this
layer replaces any existing log-targets. This file is loaded at init time
by `pebble add syslog-layer --combine` (Phase 3). It is shared by all rock
containers — that's why it's a shared file, not per-container.

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
never consider the database "up." The `pgrep -x -c pebble || pgrep -x -c
supervisord` OR is the coexistence mechanism at the host/container boundary.

> **When you migrate your own container**, check every
> `docker_image_ctl.j2` readiness block that names your container and add
> the pebble OR. This is a one-time, shared edit.

### 6.6 `build_rocks.sh` — the standalone build orchestrator

```bash
#!/bin/bash

# Finish `make SONIC_BUILD_JOBS=4 target/sonic-vs.img.gz` first
rocklist=(
    "dockers/docker-database"
    "dockers/docker-sonic-mgmt-framework"
    "dockers/docker-eventd"
    "dockers/docker-router-advertiser"
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
(shown in its current state; the docker-database commit had only the
single `dockers/docker-database` entry in `rocklist`.)

Walkthrough:

1. **Stage build artifacts** into each container's `debs/`, `files/`,
   `python-wheels/` dirs. These are the dirs `rockcraft.yaml`'s `source: .`
   picks up. They are gitignored (next section).
2. **Generate `envs`** with `IMAGE_VERSION` = branch-commit. This is the
   file `docker-database-init.sh` sources in the pebble preamble.
3. **`rockcraft clean` + `rockcraft pack`** builds the `.rock` OCI archive.
4. **`rockcraft.skopeo copy`** converts the `.rock` into a Docker daemon
   image tagged `<rockname>:latest`. `--insecure-policy` is needed because
   the default skopeo policy doesn't know about rocks. Note it's
   `rockcraft.skopeo`, *not* bare `skopeo` — Rockcraft ships a patched copy.
5. **Cleanup** the staged `debs/files/python-wheels/envs` and the `.rock`
   (they're regenerated each run; keeping them would bloat the tree and
   risk stale artifacts).
6. **`docker save | pigz`** produces `target/<rockname>.gz` — the same
   format the Makefile produces for Dockerfile containers, so the
   downstream image assembly treats them identically.
7. **`docker rmi -f`** removes the local image to keep the daemon clean
   across iterations.

> **Why standalone, not in the Makefile?** Rockcraft needs LXD and runs on
> the host, but `make` builds inside a `sonic-slave-*` container that
> doesn't have LXD/rockcraft. Integrating rockcraft into the Makefile graph
> would require restructuring the slave container. The accepted trade-off
> is a manual two-step build: `make ... && ./build_rocks.sh`.

### 6.7 `.gitignore` — rockcraft build artifacts

```gitignore
# Copied files for rockcraft build
dockers/*/debs/
dockers/*/files/
dockers/*/python-wheels/
dockers/*/envs
dockers/*/*.rock

# Installer-related files and directories
installer/x86_64/platforms/
installer/platforms/

# Misc. files
*service
justfile
```
The `dockers/*/` patterns cover the staged `debs/`, `files/`,
`python-wheels/`, `envs` and the built `.rock` for *every* container dir,
so adding a new container to `build_rocks.sh`'s `rocklist` needs no
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
```
`build_rocks.sh` produces `target/docker-database.gz`.

### 7.2 Verification checklist

1. `make target/sonic-vs.img.gz` still succeeds — the Dockerfile path is
   unmodified.
2. `build_rocks.sh` completes and `target/docker-database.gz` exists.
3. Load the image and start the container; `redis-cli PING` returns `PONG`.
4. `pebble logs` (or `docker logs`) shows no `ImportError` or
   `error while loading shared libraries` messages.
5. `docker_image_ctl.j2` correctly detects the pebble-based container
   (the readiness wait completes).

### 7.3 Runtime dependencies discovered during testing

These were not in the Phase 1 map because the full Ubuntu base image
provided them transitively. They were found missing at runtime and added to
`install-unchiselled-packages`:

| Package | Provides | Needed by |
|---|---|---|
| `libpython3.14` | `libpython3.14.so.1.0` | swsscommon Python bindings |
| `libboost-serialization1.83.0` | `libboost_serialization.so` | libswsscommon |
| `libxxhash0` | `libxxhash.so` | libyang3 |

**How to discover these for your container:** build the rock, start it,
run the container's main binary, and watch for `error while loading shared
libraries: libX.so.Y: cannot open shared object file`. Then `apt-file
search libX.so.Y` on a Resolute system to find the package, and add it to
`install-unchiselled-packages`. Iterate until clean.

> **Note:** the AI design doc also listed `libpython3.14-stdlib` and
> `libpython3.14-minimal` as separate full packages here. The committed code
> does **not** include them — the `python3.14_standard` chisel slice covers
> the stdlib, and `libpython3.14` covers the shared library. Follow the
> code.

---

## 8. Reusable Migration Checklist

Apply this to your own container. Each item maps to a phase above.

**Analysis (Phase 1):**
- [ ] Identify your container's Docker layer chain (parent → ... → yours).
- [ ] For each layer, read its `Dockerfile.j2` *and* its `rules/*.mk`
      (`_DEPENDENT_PACKAGES`, `_PYTHON_WHEELS`, `_FILES`).
- [ ] Build the 4-category × classification table (apt / pip / SONiC-debs /
      files; needed / drop-supervisord / drop-build-only / dedup).
- [ ] Resolve every row to a rockcraft landing (part, slice, dpkg -x, pip,
      organize, or override-prime).

**rockcraft.yaml (Phase 2):**
- [ ] Choose `base: bare` + `build-base: ubuntu@26.04` (chisel) or
      `base: ubuntu@26.04` (full-base). Chisel = smaller but more work.
- [ ] Define pebble `services`: rsyslogd (startup: enabled), your init
      (startup: enabled, on-success: ignore), your daemons (started by
      init after config render).
- [ ] Split parts: full packages in one `plugin: nil` part; chisel slices
      + `dpkg -x` + `pip3 install` in a `plugin: dump` part.
- [ ] `organize` every file to its runtime path.
- [ ] `override-prime`: symlinks (python3, awk), rsyslog.conf copy (not in
      organize!), any Dockerfile `sed` reproduction, manifest copy.
- [ ] Verify YAML: `python3 -c "import yaml; yaml.safe_load(open('rockcraft.yaml'))"`.

**Init script (Phase 3):**
- [ ] Add the `USE_PEBBLE` detection preamble (pgrep, source envs, syslog
      layer add+replan).
- [ ] Guard each supervisord-specific block with `if [[ "$USE_PEBBLE" != "true" ]]`.
- [ ] Replace `exec supervisord` with `pebble start <services>` under pebble.
- [ ] Verify: `grep supervisord` still shows the supervisord path is intact;
      `grep pebble` shows the new path. Run `bash -n` for syntax.

**Build system (Phase 4):**
- [ ] If your container needs a *new* shared file, add it to
      `rules/scripts.mk` (guarded by `ifeq ($(BLDENV), resolute)`), append
      to `SONIC_COPY_FILES`, add `CACHE_MODE=none` in `rules/scripts.dep`,
      and add to the relevant `rules/<container>.mk` `_FILES`.
- [ ] Add your container to `build_rocks.sh`'s `rocklist`.
- [ ] Update every `docker_image_ctl.j2` readiness block that names your
      container to accept pebble OR supervisord.
- [ ] Confirm `.gitignore` patterns already cover your container's
      `debs/files/python-wheels/envs/*.rock` (they do, via `dockers/*/`).

**Build & verify (Phase 5):**
- [ ] `make target/sonic-vs.img.gz` still passes.
- [ ] `./build_rocks.sh` produces `target/<your-container>.gz`.
- [ ] Container starts; main daemon responds; no missing-library errors.
- [ ] `docker_image_ctl.j2` readiness wait completes for your container.

---

## 9. Pitfalls and Resolute-specific Notes

### 9.1 Python 3.14 paths

Resolute ships Python 3.14 (Noble had 3.12). Every Python path in
`rockcraft.yaml` must use `python3.14` and `usr/lib/python3.14/dist-packages/`:
the `pip3 install -t` target, the `python3.14_standard` slice, the
`ln -sf /usr/bin/python3.14 usr/bin/python3` symlink, and the
`mv usr/lib/python3.14/dist-packages/bin/* usr/bin/` in `override-prime`.
Getting any of these wrong produces a rock where `python3` is missing or
wheels are installed to a path Python doesn't search.

### 9.2 `jinjanate` vs `j2`

Resolute uses `jinjanate` (the `jinjanator` pip package) for template
rendering, not the `j2` command (the `j2cli` package) used on Noble. The
init script calls `jinjanate /usr/share/sonic/templates/...j2`. Ensure
`jinjanator` is in your pip install list. (docker-eventd's `rockcraft.yaml`
still uses `j2` for some rsyslog template rendering — check what your
container's scripts actually invoke.)

### 9.3 rsyslog: omrelp, not omfwd

Resolute's `rsyslog.conf` uses the `omrelp` output module (TCP 2514,
reliable delivery) rather than Noble's `omfwd` (UDP 514). This is why
`rsyslog-relp` is in `install-unchiselled-packages`. The
`syslog-layer.yaml` pebble layer's `location: udp://127.0.0.1:514/` is the
*pebble→rsyslog* hop (local, lossy is fine); rsyslog then forwards to the
host via omrelp. Don't "fix" the UDP location to TCP — it's intentionally
the local hop.

### 9.4 Hardcoded deb filenames

The `dpkg -x debs/libyang3_3.13.6-1ubuntu0.1_amd64.deb ...` lines embed
versions. When a SONiC package version bumps, the rock build breaks until
you update the filename. **Mitigation:** use globs (`debs/libyang3_*.deb`)
as the later docker-eventd migration does. If you copy the docker-database
`rockcraft.yaml` as a template, consider switching to globs.

### 9.5 The `redis` user and `chown -R redis:redis`

Under supervisord, redis runs as the `redis` user, so the init script
`chown -R redis:redis` the data dirs. Under pebble in the chiselled rock,
the `redis` service runs as root and those chowns are skipped. The `redis`
user/group themselves come from the `redis-server_bins` (and
`base-passwd_data`) chisel slices, *not* from a manual `echo` in
`override-prime`. (The AI design doc claimed manual `echo` lines exist; they
do not in the committed code.) If your container runs a daemon as a
non-root user, verify the user comes from a slice before relying on it.

### 9.6 `rsyslog.conf` copy timing

Copying `rsyslog.conf` in `organize` (Phase 2) silently fails because the
`rsyslog` stage-package's own `/etc/rsyslog.conf` overwrites it during
staging. The copy must be in `override-prime`. This is a Rockcraft
ordering subtlety that's easy to get wrong and hard to debug (the symptom is
"my rsyslog config is ignored"). Always put files that conflict with a
stage-package's file in `override-prime`.

### 9.7 Multi-ASIC / VoQ scope

The docker-database rock's static pebble services only start one Redis
instance. The Dockerfile path, by rendering `supervisord.conf.j2` per
instance, supports multi-ASIC and VoQ chassis. This is an **accepted scope
limit**, not a bug. If you migrate a container that must support
multi-ASIC, you will need dynamic pebble layer generation (the init script
generates a pebble layer per instance and `pebble add` + `pebble replan`),
which is future work beyond this case study.

### 9.8 `rockcraft.skopeo`, not `skopeo`

Use the `rockcraft.skopeo` binary shipped with the rockcraft snap. Bare
`skopeo` may lack the policy support for `.rock` OCI archives. The
`--insecure-policy` flag is required.

### 9.9 Build graph integration is intentionally absent

`build_rocks.sh` runs on the host after `make`. Don't try to fold rockcraft
into `slave.mk` / `rules/*.mk` without also reworking the `sonic-slave`
container to include LXD and rockcraft — that's a larger effort explicitly
out of scope for this migration.

---

## 10. Appendix — File Inventory

### New files

| Path | Purpose | Commit |
|---|---|---|
| `dockers/docker-database/rockcraft.yaml` | The rock manifest (Phase 2) | `d319c706f` |
| `files/rsyslog/syslog-layer.yaml` | Shared pebble syslog layer (Phase 4.4) | `6853735e9` |
| `build_rocks.sh` | Standalone rock build orchestrator (Phase 4.6) | `d319c706f` |

### Modified files

| Path | Change | Commit |
|---|---|---|
| `dockers/docker-database/docker-database-init.sh` | `USE_PEBBLE` branch (Phase 3) | `d319c706f` |
| `rules/scripts.mk` | `RSYSLOG_CONF`, `RSYSLOG_PEBBLE_LAYER` vars + `SONIC_COPY_FILES` (Phase 4.1) | `6853735e9` |
| `rules/scripts.dep` | `CACHE_MODE=none` for the two new files (Phase 4.2) | `6853735e9` |
| `rules/docker-config-engine-resolute.mk` | Add the two files to `_FILES` (Phase 4.3) | `6853735e9` |
| `files/build_templates/docker_image_ctl.j2` | pebble OR supervisord readiness (Phase 4.5) | `6853735e9` |
| `.gitignore` | rockcraft build artifacts (Phase 4.7) | `6853735e9` |

### Untouched (coexistence)

| Path | Why untouched |
|---|---|
| `dockers/docker-database/Dockerfile.j2` | Dockerfile path must keep working |
| `dockers/docker-database/supervisord.conf.j2` | supervisord-specific |
| `dockers/docker-database/critical_processes.j2` | supervisord-specific |
| `dockers/docker-base-resolute/etc/rsyslog.conf` | Referenced by `$(RSYSLOG_CONF)_PATH`, not modified |

---

*End of guide. Cross-reference the two reference commits (`6853735e9`,
`d319c706f`) and the committed source files for any detail this guide
summarizes. Where this guide and the earlier AI-generated design documents
disagree, the source code is authoritative.*