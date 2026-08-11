# Rockcraft & Pebble Reference PR Design

## Objective

Create a reference pull request that demonstrates how Rockcraft and Pebble are
integrated into SONiC, starting from the Ubuntu Noble base (`origin/202405_noble`).
The PR is for customer demonstration only and will not be merged. It does not
need to be build-perfect, but should present a clean, logical narrative.

## Base Branch

`origin/202405_noble` (commit `3b003c365`).

This branch already contains all Debian-to-Ubuntu Noble migration work and has
no rock/pebble files. The only rock-related residue is two commented-out
rockcraft lines in `slave.mk`, which are harmless.

## Approach

**Final-state snapshot** (Approach A): branch from `origin/202405_noble`, then
checkout the final versions of rock/pebble-related files from
`feature_noble_build` HEAD (`ef2da9d2a`). Squash into 4 logical commits.

No cherry-picking, no git-filter-repo. This avoids all conflict resolution from
the 46 messy commits that mix rock/pebble with unrelated changes.

## File Classification

### Files to include (checkout from feature_noble_build HEAD)

**Rockcraft manifests** (21 files):
- `dockers/docker-database/rockcraft.yaml`
- `dockers/docker-dhcp-relay/rockcraft.yaml`
- `dockers/docker-eventd/rockcraft.yaml`
- `dockers/docker-fpm-frr/rockcraft.yaml`
- `dockers/docker-iccpd/rockcraft.yaml`
- `dockers/docker-lldp/rockcraft.yaml`
- `dockers/docker-macsec/rockcraft.yaml`
- `dockers/docker-mux/rockcraft.yaml`
- `dockers/docker-nat/rockcraft.yaml`
- `dockers/docker-orchagent/rockcraft.yaml`
- `dockers/docker-platform-monitor/rockcraft.yaml`
- `dockers/docker-router-advertiser/rockcraft.yaml`
- `dockers/docker-sflow/rockcraft.yaml`
- `dockers/docker-snmp/rockcraft.yaml`
- `dockers/docker-sonic-gnmi/rockcraft.yaml`
- `dockers/docker-sonic-mgmt-framework/rockcraft.yaml`
- `dockers/docker-teamd/rockcraft.yaml`
- `platform/broadcom/docker-syncd-brcm/rockcraft.yaml`
- `platform/vs/docker-gbsyncd-vs/rockcraft.yaml`
- `platform/vs/docker-syncd-vs/rockcraft.yaml`

**Rock init scripts** (~7 files):
- `dockers/docker-database/rock-database-init.sh`
- `dockers/docker-orchagent/rock-orchagent-init.sh`
- `dockers/docker-dhcp-relay/rock_init.sh`
- `dockers/docker-fpm-frr/rock_init.sh`
- `dockers/docker-mux/rock-init.sh`
- `dockers/docker-platform-monitor/rock_init.sh`
- `dockers/docker-router-advertiser/rock-init.sh`

**Build script** (1 file):
- `build_rocks.sh`

**Pebble converter** (1 file):
- `dockers/docker-dhcp-relay/supervisord_ini_to_pebble_yml.py`

**New runtime configuration files** (9 files, not present on base):
- `files/rsyslog/00-load-omprog.conf`
- `files/rsyslog/rsyslog.conf`
- `files/supervisor/supervisord.conf`
- `files/build_templates/syslog-layer.yaml`
- `dockers/docker-database/redis.conf`
- `dockers/docker-dhcp-relay/dhcp_relay_events.conf`
- `dockers/docker-fpm-frr/bgp_events.conf`
- `dockers/docker-orchagent/swss_events.conf`

**Modified scripts with pebble integration** (17 files, exist on base but
have rock/pebble-related changes in their base-to-HEAD diff):
- `dockers/docker-eventd/start.sh`
- `dockers/docker-iccpd/start.sh`
- `dockers/docker-lldp/start.sh`
- `dockers/docker-lldp/waitfor_lldp_ready.sh`
- `dockers/docker-macsec/start.sh`
- `dockers/docker-nat/start.sh`
- `dockers/docker-orchagent/swssconfig.sh`
- `dockers/docker-orchagent/wait_for_link.sh.j2`
- `dockers/docker-router-advertiser/wait_for_link.sh.j2`
- `dockers/docker-sflow/start.sh`
- `dockers/docker-snmp/start.sh`
- `dockers/docker-sonic-gnmi/start.sh`
- `dockers/docker-sonic-mgmt-framework/start.sh`
- `dockers/docker-teamd/start.sh`
- `dockers/docker-database/docker-database-init.sh`
- `dockers/docker-fpm-frr/start.sh` (if present and modified)
- `files/build_templates/docker_image_ctl.j2`
- `platform/broadcom/docker-syncd-brcm/start.sh`

**Build system wiring** (2 files):
- `rules/scripts.mk`
- `rules/scripts.dep`

### Files to exclude

- All `.github/` files (10 files) — CI/testflinger workflows, not needed
- `diff.submodule.txt` — unrelated artifact
- `spread.yaml` — test infrastructure, not needed
- `dockers/docker-database/task.yaml` — test file, deleted on HEAD
- `dockers/tests/utils.sh` — test file, deleted on HEAD
- `dockers/docker-orchagent/docker-orchagent-init.sh` — changes are not rock-related
- `dockers/docker-platform-monitor/docker_init.sh` — changes are not rock-related
- All `rules/docker-*jammy.*` (6 files) — superseded by noble equivalents
- `.gitignore` — user requested exclusion
- `sonic-slave-noble/Dockerfile.j2` — only build-log silencing, not rock-related
- CPLD driver files (`i2c-mux-accton_as5812_54x_cpld.c`,
  `accton-as6712-32x-cpld.c`, `sai.profile`) — unrelated platform fix
- `platform/broadcom/saibcm-modules/debian/rules` — unrelated SAI build change
- `rules/libnl3.mk` — unrelated libnl migration
- `scripts/run_with_retry` — unrelated build retry change
- 86 files that are identical between base and HEAD — no changes needed

## Commit Structure (4 squash commits)

1. **Add rockcraft manifests and build_rocks.sh**
   - All `rockcraft.yaml` files
   - `build_rocks.sh`

2. **Add runtime configuration files and build system wiring**
   - `files/rsyslog/00-load-omprog.conf`
   - `files/rsyslog/rsyslog.conf`
   - `files/supervisor/supervisord.conf`
   - `files/build_templates/syslog-layer.yaml`
   - `dockers/docker-database/redis.conf`
   - `dockers/docker-dhcp-relay/dhcp_relay_events.conf`
   - `dockers/docker-fpm-frr/bgp_events.conf`
   - `dockers/docker-orchagent/swss_events.conf`
   - `rules/scripts.mk`
   - `rules/scripts.dep`

3. **Add pebble init scripts and service management**
   - All `*rock*init.sh` files
   - `dockers/docker-dhcp-relay/supervisord_ini_to_pebble_yml.py`
   - All modified `start.sh` scripts (pebble start/replan calls)
   - `dockers/docker-orchagent/swssconfig.sh`
   - `dockers/docker-orchagent/wait_for_link.sh.j2`
   - `dockers/docker-router-advertiser/wait_for_link.sh.j2`
   - `files/build_templates/docker_image_ctl.j2`
   - `platform/broadcom/docker-syncd-brcm/start.sh`

4. **Fix database rock boot**
   - `dockers/docker-database/docker-database-init.sh`

## Branch

- Branch name: `202405_rock_pebble` (created from `origin/202405_noble`)
- Will not be merged; reference only

## Limitations

- The PR may not build successfully without the full build environment.
- Some rock init scripts or configs may reference files or paths that only
  exist in the complete `feature_noble_build` tree.
- The 86 identical files and excluded unrelated changes mean the PR is not a
  byte-for-byte subset of `feature_noble_build`, but it captures all
  rock/pebble functional changes.
