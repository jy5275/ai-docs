# docker-orchagent Rockcraft + Pebble Migration Plan (Resolute)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans or superpowers:subagent-driven-development.
>
> Parent spec: `2026-07-27-rockcraft-pebble-resolute-containers-migration-meta-spec-en.md` (section refs below). Closest siblings: `dockers/docker-fpm-frr` (approach B, rock-only start.sh, gate polling) and `dockers/docker-nat` (swss-layer deb set).

**Goal:** Migrate `docker-orchagent` (container `swss`) from Dockerfile + supervisord to Rockcraft + Pebble on `202605_resolute_rock`, Docker path coexisting, and pass §11.

**Architecture:** Approach B (§7.2/§7.3). `rockcraft.yaml` declares only `rsyslogd`/`start`; a rock-only `start.sh` absorbs `docker-init.j2`, renders `pebble-layer.j2` (translated from `supervisord.conf.j2` + the three conditional `.conf` snippets) in the same `sonic-cfggen` call as the other templates, and starts daemons in the supervisord `dependent_startup_wait_for` order.

**Tech Stack:** rockcraft (ubuntu@26.04), pebble, sonic-cfggen/Jinja2, bash.

## Global Constraints

- `base: ubuntu@26.04`, `build-base: ubuntu@26.04`; stage-packages by package name; debs via `dpkg -x debs/<pkg>_*.deb`.
- No supervisord, no service `environment:`; no `envs` copy (start.sh never uses `IMAGE_VERSION`, §3.2).
- Dockerfile.j2 / docker-init.j2 / supervisord.conf.j2 / rules/docker-orchagent.mk unchanged (§10.3).
- `.dep` filter-outs `rockcraft.yaml` and `pebble-layer.j2` (§4.2). Native image already (`SONIC_INSTALL_DOCKER_IMAGES`), no .mk change.

## Environment notes (verified 2026-09-30)

- Local `202605_resolute_rock` == origin == PR #9 head `f8e6a24df`; 14 rocks in rocklist, orchagent not yet.
- `target/docker-orchagent.gz` exists (Docker path built → §11.1 skippable); swss-layer debs and `scapy-2.6.1.dev0` wheel in `target/`.
- Baseline `et3-dh3-f-sw1` (broadcom, no VLAN): swss `supervisorctl status` = RUNNING: portsyncd orchagent coppmgrd neighsyncd vlanmgrd intfmgrd portmgrd fabricmgrd buffermgrd vrfmgrd nbrmgrd vxlanmgrd tunnelmgrd fdbsyncd countersyncd rsyslogd; EXITED: gearsyncd swssconfig restore_neighbors enable_counters (+ supervisord listeners). pip: pyroute2 0.5.14, scapy 2.6.1.dev0, netifaces, protobuf.
- `ENABLE_ASAN ?= n` (rules/config): ASAN `environment=` branches are not reproduced.

## Decisions locked

| Item | Decision |
|---|---|
| Approach | B: set of daemons depends on `switch_type==fabric`, `VLAN`, `chassis-packet`, `DualToR` — all CONFIG_DB, so the template decides; the rock exposes exactly the baseline's service set. |
| `gearsyncd` | sub-second one-shot → inline in start.sh (§6). |
| `swssconfig.sh` | one-shot gate (waits host `touch /ready`) → inline, blocking; everything `wait_for=swssconfig:exited` follows. |
| `restore_neighbors.py` | one-shot, sub-second on cold boot, ≤110s on warm → inline background `&`, `wait` at end of start.sh. |
| `wait_for_link.sh` | gate for ndppd; may exit instantly → inline, then `pebble start ndppd`. |
| `enable_counters.py` | sleeps 60/180s then exits → pebble service, `on-success/on-failure: ignore`. |
| restart policy | `autorestart=false` daemons: pebble default (teamd/fpm-frr precedent); `autorestart=unexpected` (countersyncd, arp_update, ndppd, tunnel_packet_handler): `on-success: ignore` (pmon precedent). |
| listeners / critical_processes / watchdog_processes | dropped (supervisord-only; same as other rocks). |
| `pebble-layer.j2` in Docker image | Dockerfile `COPY *.j2` also copies it — inert, accepted to keep Dockerfile unchanged. |

## Files

- Create: `dockers/docker-orchagent/{rockcraft.yaml,pebble-layer.j2,start.sh}` (start.sh mode 755)
- Modify: `build_rocks.sh` (append `"dockers/docker-orchagent"`), `rules/docker-orchagent.dep`

---

## Task 1: rock sources

- [ ] Create `dockers/docker-orchagent/rockcraft.yaml`:

```yaml
name: docker-orchagent
summary: SONiC orchagent container
description: A rock for SONiC orchagent (swss) container
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

parts:
  setup-orchagent:
    plugin: dump
    source: .
    override-build: |
      craftctl default

      # Install SONiC debs (wildcard filenames)
      dpkg -x debs/socat_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libswsscommon_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libyang3_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/python3-libyang_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/python3-swsscommon_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/sonic-db-cli_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/sonic-eventd_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libsairedis_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libsaimetadata_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libteam5_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libteamdctl0_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnexthopgroup_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libdashapi_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/swss_*.deb ${CRAFT_PART_INSTALL}

      # Clean up deb/wheel source files
      rm -rf ${CRAFT_PART_INSTALL}/debs ${CRAFT_PART_INSTALL}/python-wheels

    organize:
      start.sh: usr/bin/start.sh
      pebble-layer.j2: usr/share/sonic/templates/pebble-layer.j2
      orchagent.sh: usr/bin/orchagent.sh
      swssconfig.sh: usr/bin/swssconfig.sh
      buffermgrd.sh: usr/bin/buffermgrd.sh
      enable_counters.py: usr/bin/enable_counters.py
      tunnel_packet_handler.py: usr/bin/tunnel_packet_handler.py
      orch_zmq_tables.conf.j2: usr/share/sonic/templates/orch_zmq_tables.conf.j2
      switch.json.j2: usr/share/sonic/templates/switch.json.j2
      vxlan.json.j2: usr/share/sonic/templates/vxlan.json.j2
      ipinip.json.j2: usr/share/sonic/templates/ipinip.json.j2
      ports.json.j2: usr/share/sonic/templates/ports.json.j2
      ndppd.conf.j2: usr/share/sonic/templates/ndppd.conf.j2
      wait_for_link.sh.j2: usr/share/sonic/templates/wait_for_link.sh.j2
      files/arp_update: usr/bin/arp_update
      files/arp_update_vars.j2: usr/share/sonic/templates/arp_update_vars.j2
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
      - libdaemon0
      - libdbus-1-3
      - libjansson4
      - python3-redis
      - python3-yaml
      - python3-cffi-backend
      # SONiC deb runtime dependencies
      - libboost-serialization1.83.0
      - libhiredis1.1.0
      - libxxhash0
      # libnl-3/genl/route/nf come along as hard Depends of libnl-cli-3-200
      - libnl-cli-3-200
      - libpython3.14
      # swss-layer inherited runtime dependencies
      - iputils-ping
      - libprotobuf32t64
      # swss deb Depends (orchagent links libjemalloc)
      - libjemalloc2
      # orchagent-specific runtime dependencies (Dockerfile.j2 apt-get install)
      - ifupdown
      - arping
      - ndisc6
      - tcpdump
      - bridge-utils
      - conntrack
      - ndppd
      - python3-protobuf
      - pciutils
      - python3-netifaces
      # pyroute2 0.5.14 imports distutils (gone in python 3.12+); setuptools'
      # distutils-precedence.pth shim provides it, as in the Docker path
      - python3-setuptools

    prime:
      # Exclude unnecessary artifacts that `source: .` dumps at the rock root
      - -files
      - -envs
      - -python-debs
      - -vcache
      - -base_image_files
      - -buildinfo
      - -Dockerfile*
      # Docker/supervisord-path only
      - -docker-init.j2
      - -supervisord.conf.j2
      - -critical_processes.j2
      - -watchdog_processes.j2
      - -vlan_vars.j2
      - -arp_update.conf
      - -ndppd.conf
      - -tunnel_packet_handler.conf

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
      # orchagent wheels ($(DOCKER_ORCHAGENT)_PYTHON_WHEELS)
      - ./python-wheels/scapy-2.6.1.dev0-py3-none-any.whl
      # Dependencies of restore_neighbors.py (Dockerfile.j2 pip3 install)
      - pyroute2==0.5.14
    stage-packages:
      - python3-venv

  add-user:
    plugin: nil
    after: [setup-orchagent]
    overlay-script: |
      groupadd -R $CRAFT_OVERLAY syslog
      useradd -R $CRAFT_OVERLAY -M -r --system -g adm syslog
    prime:
      - etc/passwd
      - etc/group
```

- [ ] Create `dockers/docker-orchagent/pebble-layer.j2`:

```jinja
services:
{% set is_fabric_asic = 0 %}
{% if DEVICE_METADATA.localhost.switch_type %}
{% if DEVICE_METADATA.localhost.switch_type == "fabric" %}
{% set is_fabric_asic = 1 %}
{% endif %}
{% endif %}
{% if is_fabric_asic == 0 %}
  portsyncd:
    override: replace
    command: /usr/bin/portsyncd
{% endif %}
  orchagent:
    override: replace
    command: /usr/bin/orchagent.sh
{% if is_fabric_asic == 0 %}
  coppmgrd:
    override: replace
    command: /usr/bin/coppmgrd
  neighsyncd:
    override: replace
    command: /usr/bin/neighsyncd
  vlanmgrd:
    override: replace
    command: /usr/bin/vlanmgrd
  intfmgrd:
    override: replace
    command: /usr/bin/intfmgrd
  portmgrd:
    override: replace
    command: /usr/bin/portmgrd
{% endif %}
  fabricmgrd:
    override: replace
    command: /usr/bin/fabricmgrd
{% if is_fabric_asic == 0 %}
  buffermgrd:
    override: replace
    command: /usr/bin/buffermgrd.sh
  vrfmgrd:
    override: replace
    command: /usr/bin/vrfmgrd
  nbrmgrd:
    override: replace
    command: /usr/bin/nbrmgrd
  vxlanmgrd:
    override: replace
    command: /usr/bin/vxlanmgrd
  tunnelmgrd:
    override: replace
    command: /usr/bin/tunnelmgrd
{% endif %}
  enable_counters:
    override: replace
    command: /usr/bin/enable_counters.py
    on-success: ignore
    on-failure: ignore
{% if is_fabric_asic == 0 %}
  fdbsyncd:
    override: replace
    command: /usr/bin/fdbsyncd
{% endif %}
  countersyncd:
    override: replace
    command: /usr/bin/countersyncd --enable-otel
    on-success: ignore
{% if VLAN or DEVICE_METADATA.localhost.switch_type == "chassis-packet" %}
  arp_update:
    override: replace
    command: /usr/bin/arp_update
    on-success: ignore
{% endif %}
{% if VLAN %}
  ndppd:
    override: replace
    command: /usr/sbin/ndppd
    on-success: ignore
{% endif %}
{% if DEVICE_METADATA.localhost.subtype == "DualToR" %}
  tunnel_packet_handler:
    override: replace
    command: /usr/bin/tunnel_packet_handler.py
    on-success: ignore
{% endif %}
```

- [ ] Create `dockers/docker-orchagent/start.sh` (`chmod 755`):

```bash
#!/usr/bin/env bash

# SONiC swss (orchagent) rock init — rock-only (rockcraft.yaml's `start` service
# is its sole consumer; the Docker path keeps ENTRYPOINT docker-init.sh, untouched).
# Reproduces docker-init.j2's config rendering, replaces the supervisord.conf
# render with a dynamic pebble layer, and starts daemons via pebble in the
# order supervisord's dependent_startup_wait_for chain imposed.

mkdir -p /etc/swss/config.d/

CFGGEN_PARAMS=" \
    -d \
    -a "{\"ASIC_VENDOR\":\"${ASIC_VENDOR:-unknown}\"}" \
    -y /etc/sonic/constants.yml \
    -t /usr/share/sonic/templates/orch_zmq_tables.conf.j2,/etc/swss/orch_zmq_tables.conf \
    -t /usr/share/sonic/templates/switch.json.j2,/etc/swss/config.d/switch.json \
    -t /usr/share/sonic/templates/vxlan.json.j2,/etc/swss/config.d/vxlan.json \
    -t /usr/share/sonic/templates/ipinip.json.j2,/etc/swss/config.d/ipinip.json \
    -t /usr/share/sonic/templates/ports.json.j2,/etc/swss/config.d/ports.json \
    -t /usr/share/sonic/templates/ndppd.conf.j2,/etc/ndppd.conf \
    -t /usr/share/sonic/templates/wait_for_link.sh.j2,/usr/bin/wait_for_link.sh \
    -t /usr/share/sonic/templates/pebble-layer.j2,/tmp/swss-layer.yaml \
"
sonic-cfggen $CFGGEN_PARAMS
SWITCH_TYPE=${SWITCH_TYPE:-`sonic-db-cli -s CONFIG_DB HGET 'DEVICE_METADATA|localhost' 'switch_type'`}
chmod +x /usr/bin/wait_for_link.sh

# Executed platform specific initialization tasks.
if [ -x /usr/share/sonic/platform/platform-init ]; then
    /usr/share/sonic/platform/platform-init
fi

# Executed HWSKU specific initialization tasks.
if [ -x /usr/share/sonic/hwsku/hwsku-init ]; then
    /usr/share/sonic/hwsku/hwsku-init
fi

IS_SUPERVISOR=/etc/sonic/chassisdb.conf
USE_PCI_ID_IN_CHASSIS_STATE_DB=/usr/share/sonic/platform/use_pci_id_chassis
ASIC_ID="asic$NAMESPACE_ID"
if [ -f "$IS_SUPERVISOR" ]; then
    if [ -f "$USE_PCI_ID_IN_CHASSIS_STATE_DB" ]; then
        while true; do
            PCI_ID=$(sonic-db-cli -s CHASSIS_STATE_DB HGET "CHASSIS_FABRIC_ASIC_TABLE|$ASIC_ID" asic_pci_address)
            if [ -z "$PCI_ID" ]; then
                sleep 3
            else
                # Update asic_id in CONFIG_DB, which is used by orchagent and fed to syncd
                if [[ $PCI_ID == ????:??:??.? ]]; then
                    sonic-db-cli CONFIG_DB HSET 'DEVICE_METADATA|localhost' 'asic_id' ${PCI_ID#*:}
                    break
                fi
            fi
        done
    fi
fi

# Start a service only if it was rendered into the swss layer.
start_if_defined()
{
    for svc in "$@"; do
        if pebble services "$svc" 2>/dev/null | grep -q "^$svc "; then
            pebble start "$svc" || true
        fi
    done
}

if pgrep -x pebble > /dev/null 2>&1; then
    LAYER_FILE="/usr/share/sonic/templates/syslog-layer.yaml"
    pebble add syslog-layer --combine $LAYER_FILE
    pebble replan

    pebble add swss-layer --combine /tmp/swss-layer.yaml
    pebble replan

    # gearsyncd is a sub-second one-shot (pushes gearbox config, exits); run inline.
    if [ "$SWITCH_TYPE" != "fabric" ]; then
        /usr/bin/gearsyncd -p /usr/share/sonic/hwsku/gearbox_config.json
    fi

    # orchagent waits for portsyncd:running (rsyslogd:running on fabric asics).
    start_if_defined portsyncd orchagent

    # coppmgrd and swssconfig wait for orchagent:running.
    start_if_defined coppmgrd

    # swssconfig is a one-shot gate: it waits for the host to touch /ready,
    # then loads the config.d JSONs. Everything below waits for swssconfig:exited.
    /usr/bin/swssconfig.sh

    # restore_neighbors is a one-shot (sub-second unless system warm reboot);
    # run it alongside the daemons below, as supervisord did.
    if [ "$SWITCH_TYPE" != "fabric" ]; then
        /usr/bin/restore_neighbors.py &
    fi

    # Original supervisord priority order.
    start_if_defined neighsyncd arp_update vlanmgrd intfmgrd portmgrd fabricmgrd \
        buffermgrd enable_counters tunnel_packet_handler vrfmgrd nbrmgrd \
        vxlanmgrd tunnelmgrd fdbsyncd countersyncd

    # ndppd waits for wait_for_link:exited (a one-shot gate on VLAN interfaces).
    if pebble services ndppd 2>/dev/null | grep -q "^ndppd "; then
        /usr/bin/wait_for_link.sh
        pebble start ndppd || true
    fi

    wait
fi
```

- [ ] Render check of the layer with a fake config (no switch needed):

```bash
cd dockers/docker-orchagent
for md in '{}' '{"switch_type":"fabric"}' '{"subtype":"DualToR"}'; do
  python3 -c "import jinja2,json,sys,yaml;t=jinja2.Template(open('pebble-layer.j2').read());print(yaml.safe_load(t.render(DEVICE_METADATA={'localhost':json.loads(sys.argv[1])},VLAN={}))['services'].keys())" "$md"
done
```
Expected: non-fabric = 16 services (no arp_update/ndppd); fabric = orchagent fabricmgrd enable_counters countersyncd; DualToR adds tunnel_packet_handler.

## Task 2: build integration

- [ ] `build_rocks.sh`: append `"dockers/docker-orchagent"` after `"dockers/docker-fpm-frr"`.
- [ ] `rules/docker-orchagent.dep` line 5 → `DEP_FILES   += $(filter-out $(DPATH)/rockcraft.yaml $(DPATH)/pebble-layer.j2,$(shell git ls-files $(DPATH)))`

## Task 3: verification (§11)

- [ ] §11.2: build only this rock (same steps as one `build_rocks.sh` loop iteration), `docker load -i target/docker-orchagent.gz`.
- [ ] ldd every ELF in `usr/bin` of the rock: no `not found`.
- [ ] §11.4: `docker run -d --name orchagent_rock ...`; expect `start` blocked in swssconfig (no /ready, no redis), no ImportError/missing .so in `pebble logs`.
- [ ] §11.5: `stat` gz birth time, `make target/sonic-vs.img.gz`, birth time unchanged.
- [ ] §11.6: boot VS VM; `docker exec swss pebble services` matches baseline set; `pebble changes` no Error; logs free of defect markers; `show interfaces status` works (orchagent programmed ports).
