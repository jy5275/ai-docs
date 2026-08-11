# Chisel Slice Definitions for SONiC Resolute Containers

**Date:** 2026-07-30
**Branch:** `202605_resolute_rock` (for reference; no changes made here)
**Target repo:** `canonical/chisel-releases`, branch `ubuntu-26.04`
**Scope:** 38 Ubuntu packages across 20 containers (meta-spec list). 29 packages
already covered (18 existing SDFs + 6 open PR / sub-package + 2 renamed +
3 not-direct) and excluded from creation.

## 1. Goal

Create missing chisel slice definitions (SDFs) for all Ubuntu apt packages required
by the SONiC Resolute containers, enabling fully chiselled Rockcraft builds
(`base: bare` + slices only, no full `stage-packages`).

All work is done in `canonical/chisel-releases:ubuntu-26.04/slices/`. No changes
are made to the sonic-buildimage repository.

## 2. Package Inventory

67 Ubuntu packages originally identified from Dockerfile.j2 `apt install` and
rockcraft.yaml `stage-packages` lines. 29 excluded (see section 4). 38 packages
remain for creation, 3 for refinement.

"Direct" column: ✓ = explicitly listed in a Dockerfile.j2 `apt install` or
rockcraft.yaml `stage-packages` line. Transitive dependencies are excluded.

Difficulty scale:
- ★ : trivial — single .so, existing reference, 1-2 essential deps
- ★★ : simple — single binary or few libs, existing reference, <5 deps
- ★★★ : moderate — multiple files, config, or no reference, <10 deps
- ★★★★ : complex — daemon with config+data dirs, >10 deps, or no reference
- ★★★★★ : very complex — large package (>50 files), complex dep tree, or multi-slice structure

### 2.1 P1 — base layer shared (4 pkgs, 9★)

| #   | Package | ★  | Direct | Note |
| --- | ------- | --- | ------ | ---- |
| 1.1 | libdaemon0 | ★ | ✓ | No reference |
| 1.2 | net-tools | ★★★ | ✓ | No reference |
| 1.3 | python3-yaml | ★★ | ✓ | No reference |
| 1.4 | python3-redis | ★★★ | ✓ | No reference |

### 2.2 P2 — container-specific (31 pkgs, 76★)

| #   | Package | ★  | Direct | Needed by containers |
| --- | ------- | --- | ------ | -------------------- |
| 2.1 | radvd | ★★★ | ✓ | router-advertiser |
| 2.2 | dmidecode | ★★ | ✓ | sflow, platform-monitor |
| 2.3 | bridge-utils | ★★ | ✓ | nat, orchagent |
| 2.4 | conntrack | ★★ | ✓ | nat, orchagent |
| 2.5 | tcpdump | ★★ | ✓ | dhcp-server, orchagent |
| 2.6 | logrotate | ★★★ | ✓ | fpm-frr |
| 2.7 | kmod | ★★ | ✓ | syncd-brcm |
| 2.8 | arping | ★★ | ✓ | orchagent |
| 2.9 | ndisc6 | ★★ | ✓ | orchagent |
| 2.10 | ndppd | ★★★ | ✓ | orchagent |
| 2.11 | ifupdown | ★★★ | ✓ | orchagent |
| 2.12 | psmisc | ★★ | ✓ | platform-monitor |
| 2.13 | xxd | ★★ | ✓ | platform-monitor |
| 2.14 | librrd8t64 | ★★ | ✓ | platform-monitor |
| 2.15 | rrdtool | ★★★ | ✓ | platform-monitor |
| 2.16 | pciutils | ★★ | ✓ | orchagent, platform-monitor |
| 2.17 | libpci3 | ★ | ✓ | platform-monitor, orchagent |
| 2.18 | nvme-cli | ★★★ | ✓ | platform-monitor |
| 2.19 | smartmontools | ★★★ | ✓ | platform-monitor |
| 2.20 | python3-protobuf | ★★★ | ✓ | orchagent |
| 2.21 | python3-netifaces | ★★ | ✓ | orchagent, platform-monitor |
| 2.22 | python3-smbus | ★★ | ✓ | platform-monitor |
| 2.23 | python3-cffi | ★★★ | ✓ | config-engine |
| 2.24 | python3-bottle | ★★ | ✓ | platform-monitor |
| 2.25 | python-is-python3 | ★ | ✓ | base |
| 2.26 | rsync | ★★ | ✓ | base |
| 2.27 | libgoogle-perftools4t64 | ★★ | ✓ | fpm-frr |
| 2.28 | kea-dhcp4-server | ★★★★ | ✓ | dhcp-server |
| 2.29 | snmp | ★★★ | ✓ | snmp |
| 2.30 | snmpd | ★★★★ | ✓ | snmp |
| 2.31 | ipmitool | ★★★★ | ✓ | snmp, platform-monitor |

### 2.3 P3 — refinement (3 pkgs, 12★)

| #   | Package | ★  | Note |
| --- | ------- | --- | ---- |
| 3.1 | kea-dhcp4-server | ★★★★ | Large daemon; may need slice tuning |
| 3.2 | ipmitool | ★★★★ | Multi-backend; may need slice tuning |
| 3.3 | snmpd | ★★★★ | Large daemon; may need slice tuning |

## 3. Phased Implementation Plan

### Phase 1 — base layer coverage (4 pkgs, 9★)

- 1.1 libdaemon0
- 1.2 net-tools
- 1.3 python3-yaml
- 1.4 python3-redis

**PR:** 1

### Phase 2 — container-specific packages (31 pkgs, 76★)

| Batch | Container | Packages | ★ cum |
| ----- | --------- | -------- | ----- |
| 2A | router-advertiser | radvd | 3★ |
| 2B | sflow | dmidecode | 2★ |
| 2C | nat | bridge-utils, conntrack | 4★ |
| 2D | snmp | snmp, snmpd, ipmitool | 11★ |
| 2E | dhcp-server | tcpdump, kea-dhcp4-server | 6★ |
| 2F | orchagent | ifupdown, arping, ndisc6, bridge-utils, conntrack, ndppd, python3-protobuf, pciutils, libpci3, python3-netifaces | 22★ |
| 2G | platform-monitor | ipmitool, librrd8t64, rrdtool, python3-smbus, dmidecode, psmisc, python3-netifaces, libpci3, pciutils, nvme-cli, xxd, python3-bottle, smartmontools | 30★ |
| 2H | fpm-frr | logrotate, libgoogle-perftools4t64 | 5★ |
| 2I | syncd-brcm | kmod | 2★ |
| 2J | syncd-vs | (investigate) | ~4★ |
| 2K | base-only (mux, macsec, teamd, lldp, gnmi) | python-is-python3, rsync | 3★ |

**PRs:** 7-9

### Phase 3 — large package refinement (3 pkgs, 12★)

- kea-dhcp4-server, ipmitool, snmpd

**PR:** 1

### Summary

| Phase | Packages | ★ | PRs |
| ----- | -------- | -- | --- |
| 1 | 4 | 9★ | 1 |
| 2 | 31 | 76★ | 7-9 |
| 3 | 3 | 12★ | 1 |
| **Total** | **38** | **97★** | **9-11** |

## 4. Excluded Packages

### 4.1 Already have SDFs on ubuntu-26.04 (18 packages)

libxxhash0, libatomic1, libdbus-1-3, libjansson4, libwrap0, iptables,
libboost-thread1.83.0, libboost-log1.83.0, libboost-program-options1.83.0,
libboost-filesystem1.83.0, jq, less, curl, redis-tools, python3-setuptools,
python3-wheel, vim-tiny, perl

### 4.2 Covered by open PRs or sub-packages (6 packages)

| PR / Source | Package(s) | Note |
|---|---|---|
| [#1106](https://github.com/canonical/chisel-releases/pull/1106) | libboost-serialization1.83.0 | |
| [#1104](https://github.com/canonical/chisel-releases/pull/1104) | rsyslog, rsyslog-relp | |
| [#1004](https://github.com/canonical/chisel-releases/pull/1004) | i2c-tools | |
| [#881](https://github.com/canonical/chisel-releases/pull/881) | ethtool | |
| ubuntu-26.04 SDFs | libpython3.14 | Meta-package; content via libpython3.14-minimal + libpython3.14-stdlib (both have SDFs) |

### 4.3 Exists under different name

| Expected | Actual on ubuntu-26.04 |
|---|---|
| python3-venv | python3.14-venv |

### 4.4 Not a direct dependency

| Package | Reason |
|---|---|
| ebtables | Part of iptables package on Resolute; not separately installed |
| libjsoncpp25 | Dockerfile installs libjsoncpp-dev (build-time); runtime .so pulled transitively |
| libpcap0.8t64 | Dockerfile installs libpcap-dev (build-time); runtime .so pulled transitively |

## 5. Constraints

- Do not modify any file in sonic-buildimage.
- Each SDF file goes under `slices/<package>.yaml` in `canonical/chisel-releases:ubuntu-26.04`.
- Use existing Noble SDFs or ubuntu-26.04 SDFs as reference when available; adapt paths for Resolute.
- Each new SDF must pass `chisel cut --release . --root <tmpdir> <pkg>_<slice>` without errors.
- Phase 1 completion is the checkpoint: before proceeding to Phase 2, validate by attempting
  a fully chiselled build of docker-eventd (local only, not committed to sonic-buildimage).
- Before creating a new SDF, re-check `canonical/chisel-releases:ubuntu-26.04/slices/`
  to confirm the package is still missing (new SDFs may have been added since this plan).