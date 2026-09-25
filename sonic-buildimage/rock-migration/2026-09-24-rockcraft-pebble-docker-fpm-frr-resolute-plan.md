# docker-fpm-frr Rockcraft + Pebble Migration Plan (Resolute)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans or superpowers:subagent-driven-development.
>
> Parent spec: `2026-07-27-rockcraft-pebble-resolute-containers-migration-meta-spec-en.md` (the common pattern; section references below are to it). Canonical reference implementation: `dockers/docker-eventd` (pattern) and `dockers/docker-platform-monitor` (approach B, the closest ★★★★ sibling).

**Goal:** Migrate the `docker-fpm-frr` (bgp) container from Dockerfile + supervisord to Rockcraft + Pebble on `202605_resolute_rock`, keeping both paths coexistent, and pass the §11 verification suite including §11.6 full runtime verification.

**Approach:** **Approach B** (dynamic pebble layer via `pebble-layer.j2`), exercised under the §7.3 fallback explicitly reserved for docker-fpm-frr. Rationale: `supervisord.conf.j2` has command-level conditionals (`bgpd … -M bmp`) and 18 conditionally-rendered daemons with a dependency-ordering chain (`zsocket:exited` gate) that static `services:` entries cannot express; docker-platform-monitor already chose B for the same reasons.

## Environment notes (verified)

- Branch `202605_resolute_rock` == `origin/202605_resolute_rock` (e41bf7b7e), PR #9 in sync. 13 containers already in `build_rocks.sh` rocklist; `docker-fpm-frr` is not.
- `target/` fully populated: `target/docker-fpm-frr.gz` exists (Docker path built → **§11.1 skippable**), and `target/debs/resolute/{frr,frr-snmp,swss,libyang3,...}.deb` + `target/python-wheels/resolute/{sonic_bgpcfgd,sonic_frr_mgmt_framework,...}.whl` present.
- `rules/docker-fpm-frr.mk`: frr is already a native docker image (`SONIC_DOCKER_IMAGES += $(DOCKER_FPM_FRR)`), so **no** `SONIC_INSTALL_DOCKER_IMAGES` switch is needed (§4.2 item 2 N/A).
- frr does NOT use `container_startup.py`/`IMAGE_VERSION` → **no** `envs` copy nor `source envs` (§3.2).
- `FRR_USER_UID = 300`, `FRR_USER_GID = 300` (`rules/config:141-142`).
- `ENABLE_FRR_TCMALLOC ?= y`, so `libgoogle-perftools4t64` is required (frr deb `Depends`, and `libfrr.so.0`/daemons `NEEDED libtcmalloc.so.4`).

## Decisions locked

| Decision | Value |
|---|---|
| frrcfgd templates path | python plugin installs wheel `data_files` at `/sonic/frrcfgd` (`sys.prefix` = venv root = `/`); relocate to `/usr/local/sonic/frrcfgd` in `override-prime` so `-T` flag and `gen_frr.conf.j2` include stay byte-identical to Docker path. |
| console-script path | `/usr/bin/{bgpcfgd,frrcfgd,bgpmon,bfdmon,staticroutebfd}` (usrmerge: venv `bin/` == `usr/bin/`). |
| frr tree install | `cp -a ${CRAFT_PART_INSTALL}/frr/. …/templates/` in `override-build` (Dockerfile `COPY frr /usr/share/sonic/templates` = contents). |
| event listeners | `dependent-startup`, `supervisor-proc-exit-listener` dropped (supervisord-only; no pebble equivalent). |
| daemon order | start.sh sequential `pebble start`; `zsocket` one-shot awaited before `staticd`/`bgpd` (mirrors `dependent_startup_wait_for=zsocket:exited`). |

## Files

- Create: `dockers/docker-fpm-frr/rockcraft.yaml`, `dockers/docker-fpm-frr/start.sh`, `dockers/docker-fpm-frr/pebble-layer.j2`
- Modify: `build_rocks.sh` (append rocklist), `rules/docker-fpm-frr.dep` (§4.2 filter-out)
- Unchanged: `Dockerfile.j2`, `docker_init.sh`, `frr/**`, `.mk` (expect the 3 created/modified above)

---

## Task 1: rockcraft.yaml

Create `dockers/docker-fpm-frr/rockcraft.yaml` (skeleton §5, swss-layer deb set from docker-teamd + frr deb/wheels):

```yaml
name: docker-fpm-frr
summary: SONiC fpm-frr container
description: A rock for SONiC fpm-frr container
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
  setup-fpm-frr:
    plugin: dump
    source: .
    override-build: |
      craftctl default

      # Install SONiC debs (wildcard filenames)
      dpkg -x debs/socat_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnl-3-200_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnl-genl-3-200_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnl-route-3-200_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnl-nf-3-200_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/libnl-cli-3-200_*.deb ${CRAFT_PART_INSTALL}
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
      dpkg -x debs/frr_*.deb ${CRAFT_PART_INSTALL}
      dpkg -x debs/frr-snmp_*.deb ${CRAFT_PART_INSTALL}

      # Dockerfile COPY frr -> /usr/share/sonic/templates (contents)
      mkdir -p ${CRAFT_PART_INSTALL}/usr/share/sonic/templates
      cp -a ${CRAFT_PART_INSTALL}/frr/. ${CRAFT_PART_INSTALL}/usr/share/sonic/templates/
      rm -rf ${CRAFT_PART_INSTALL}/frr

      # Clean up deb/wheel source files
      rm -rf ${CRAFT_PART_INSTALL}/debs ${CRAFT_PART_INSTALL}/python-wheels

    organize:
      start.sh: usr/bin/start.sh
      pebble-layer.j2: usr/share/sonic/templates/pebble-layer.j2
      snmp.conf: etc/snmp/frr.conf
      TS: usr/bin/TS
      TSA: usr/bin/TSA
      TSB: usr/bin/TSB
      TSC: usr/bin/TSC
      zsocket.sh: usr/bin/zsocket.sh
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
      - libpython3.14
      # swss-layer inherited runtime dependencies
      - iputils-ping
      - libprotobuf32t64
      # frr-specific runtime dependencies
      - logrotate
      - libgoogle-perftools4t64
      - libjson-c5
      - libpcre2-posix3
      - libreadline8t64
      - libsnmp40t64

    prime:
      # Exclude unnecessary artifacts that `source: .` dumps at the rock root
      - -files
      - -envs
      - -python-debs
      - -vcache
      - -base_image_files
      - -buildinfo
      - -docker_init.sh
      - -Dockerfile*
      - -vtysh.conf

    override-prime: |
      craftctl default

      cp ${CRAFT_PROJECT_DIR}/files/rsyslog.conf etc/rsyslog.conf
      cp ${CRAFT_PROJECT_DIR}/manifest.json manifest.json

      # The python plugin installs the frr-mgmt-framework wheel data_files at
      # ${sys.prefix}/sonic/frrcfgd (= /sonic/frrcfgd). FRR expects them at
      # /usr/local/sonic/frrcfgd (pip3 default in the Docker path).
      if [ -d sonic/frrcfgd ]; then
          mkdir -p usr/local/sonic
          mv sonic/frrcfgd usr/local/sonic/frrcfgd
          rmdir sonic 2>/dev/null || true
      fi

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
      # bgp wheels
      - ./python-wheels/sonic_bgpcfgd-1.0-py3-none-any.whl
      - ./python-wheels/sonic_frr_mgmt_framework-1.0-py3-none-any.whl
      # common pip packages
      - jinjanator
      - click
      - pyangbind==0.8.7
      - lxml
    stage-packages:
      - python3-venv

  add-user:
    plugin: nil
    after: [setup-fpm-frr]
    overlay-script: |
      groupadd -R $CRAFT_OVERLAY -g 300 frr
      useradd -R $CRAFT_OVERLAY -u 300 -g 300 -M -s /bin/false frr
      groupadd -R $CRAFT_OVERLAY syslog
      useradd -R $CRAFT_OVERLAY -M -r --system -g adm syslog
    prime:
      - etc/passwd
      - etc/group
```

Notes:
- `build-packages` in `setup-fpm-frr` not needed (no build-time j2 rendering; all renders are runtime in start.sh).
- `install-python` needs no `build-packages` (all wheels are pure / binary wheels: bgpcfgd, frr-mgmt-framework, lxml).

## Task 2: pebble-layer.j2

Create `dockers/docker-fpm-frr/pebble-layer.j2` (1:1 translation of `frr/supervisord/supervisord.conf.j2` `[program:*]` sections):

```jinja
services:
  mgmtd:
    override: replace
    command: /usr/lib/frr/mgmtd -A 127.0.0.1 -P 0
  zebra:
    override: replace
    command: /usr/lib/frr/zebra -A 127.0.0.1 -s 90000000 -M dplane_fpm_sonic -M snmp --asic-offload=notify_on_offload
  zsocket:
    override: replace
    command: /usr/bin/zsocket.sh
    on-success: ignore
    on-failure: ignore
  staticd:
    override: replace
    command: /usr/lib/frr/staticd -A 127.0.0.1 -P 0
{% if DEVICE_METADATA.localhost.frr_mgmt_framework_config is defined and DEVICE_METADATA.localhost.frr_mgmt_framework_config == "true" %}
  bfdd:
    override: replace
    command: /usr/lib/frr/bfdd -A 127.0.0.1 -P 0
    kill-delay: 0s
{% endif %}
  bgpd:
    override: replace
{% if FEATURE is defined and
      (FEATURE.frr_bmp is defined and FEATURE.frr_bmp.state is defined and FEATURE.frr_bmp.state == "enabled") or
      (FEATURE.bmp is defined and FEATURE.bmp.state is defined and FEATURE.bmp.state == "enabled") %}
    command: /usr/lib/frr/bgpd -A 127.0.0.1 -P 0 -M snmp -M bmp
{% else %}
    command: /usr/lib/frr/bgpd -A 127.0.0.1 -P 0 -M snmp
{% endif %}
    kill-delay: 0s
{% if DEVICE_METADATA.localhost.frr_mgmt_framework_config is defined and DEVICE_METADATA.localhost.frr_mgmt_framework_config == "true" %}
  ospfd:
    override: replace
    command: /usr/lib/frr/ospfd -A 127.0.0.1 -P 0 -M snmp
    kill-delay: 0s
  pimd:
    override: replace
    command: /usr/lib/frr/pimd -A 127.0.0.1 -P 0
    kill-delay: 0s
{% endif %}
  fpmsyncd:
    override: replace
    command: fpmsyncd
{% if DEVICE_METADATA.localhost.frr_mgmt_framework_config is defined and DEVICE_METADATA.localhost.frr_mgmt_framework_config == "true" %}
  frrcfgd:
    override: replace
    command: /usr/bin/frrcfgd
{% else %}
  bgpcfgd:
    override: replace
    command: /usr/bin/bgpcfgd
{% endif %}
{% if DEVICE_METADATA.localhost.switch_type is defined and DEVICE_METADATA.localhost.switch_type == "chassis-packet" %}
  staticroutebfd:
    override: replace
    command: /usr/bin/staticroutebfd
    on-failure: restart
{% endif %}
{% if DEVICE_METADATA.localhost.frr_mgmt_framework_config is defined and DEVICE_METADATA.localhost.frr_mgmt_framework_config == "true" %}
{% else %}
  bgpmon:
    override: replace
    command: /usr/bin/bgpmon
    on-failure: restart
{% endif %}
{% if SYSTEM_DEFAULTS is defined and SYSTEM_DEFAULTS.software_bfd is defined and SYSTEM_DEFAULTS.software_bfd.status is defined and SYSTEM_DEFAULTS.software_bfd.status == "enabled" %}
  bfdmon:
    override: replace
    command: /usr/bin/bfdmon
    on-failure: restart
{% endif %}
{% if DEVICE_METADATA.localhost.docker_routing_config_mode is defined and (DEVICE_METADATA.localhost.docker_routing_config_mode == "unified" or DEVICE_METADATA.localhost.docker_routing_config_mode == "split-unified") %}
  vtysh_b:
    override: replace
    command: /usr/bin/vtysh -b
    on-success: ignore
    on-failure: ignore
{% endif %}
{% if WARM_RESTART is defined and WARM_RESTART.bgp is defined and WARM_RESTART.bgp.bgp_eoiu is defined and WARM_RESTART.bgp.bgp_eoiu == "true" %}
  bgp_eoiu_marker:
    override: replace
    command: /usr/bin/bgp_eoiu_marker.py
    on-success: ignore
    on-failure: ignore
{% endif %}
{% if DEVICE_METADATA.localhost.frr_mgmt_framework_config is defined and DEVICE_METADATA.localhost.frr_mgmt_framework_config == "true" %}
  pathd:
    override: replace
    command: /usr/lib/frr/pathd -A 127.0.0.1 -P 0
    kill-delay: 0s
{% endif %}
  sharpd:
    override: replace
    command: /usr/lib/frr/sharpd -A 127.0.0.1 -P 0
    kill-delay: 0s
```

## Task 3: start.sh

Create `dockers/docker-fpm-frr/start.sh`. It is rock-only (`docker_init.sh` stays the Docker ENTRYPOINT, untouched). It reproduces docker_init.sh's runtime rendering, minus the supervisord render/exec, plus the pebble orchestration:

```bash
#!/usr/bin/env bash

# SONiC bgp (FRR) rock init — rock-only (rockcraft.yaml `start` service is its
# sole consumer; the Docker path keeps ENTRYPOINT docker_init.sh, untouched).
# Reproduces docker_init.sh's config rendering, replaces the supervisord.conf
# render with a dynamic pebble layer, and starts daemons via pebble.

mkdir -p /etc/frr

FRR_VARS=$(sonic-cfggen -d \
    -y /etc/sonic/constants.yml \
    -t /usr/share/sonic/templates/isolate.j2,/usr/sbin/bgp-isolate \
    -t /usr/share/sonic/templates/unisolate.j2,/usr/sbin/bgp-unisolate \
    -t /usr/share/sonic/templates/frr_vars.j2)
CONFIG_TYPE=$(echo $FRR_VARS | jq -r '.docker_routing_config_mode')

update_default_gw()
{
   IP_VER=${1}
   GATEWAY_IP=$(ip -${IP_VER} route show default dev eth0 | awk '{print $3}')
   if [[ ! -z "$GATEWAY_IP" ]]; then
      ip -${IP_VER} route del default dev eth0
      CHECK_GATEWAY_IP=$(ip -${IP_VER} route show default dev eth0 | awk '{print $3}')
      if [[ -z "$CHECK_GATEWAY_IP" ]]; then
         ip -${IP_VER} route add default via $GATEWAY_IP dev eth0 metric 3523215360
      fi
   fi
}

write_default_zebra_config()
{
    FILE_NAME=${1}

    grep -q '^no fpm use-next-hop-groups' $FILE_NAME || {
        echo "no fpm use-next-hop-groups" >> $FILE_NAME
        echo "fpm address 127.0.0.1" >> $FILE_NAME
    }
}

if [[ ! -z "$NAMESPACE_ID" ]]; then
   update_default_gw 4
   update_default_gw 6
fi

if [ -z "$CONFIG_TYPE" ] || [ "$CONFIG_TYPE" == "separated" ]; then
    CFGGEN_PARAMS=" \
        -d \
        -y /etc/sonic/constants.yml \
        -t /usr/share/sonic/templates/bgpd/gen_bgpd.conf.j2,/etc/frr/bgpd.conf \
        -t /usr/share/sonic/templates/zebra/zebra.conf.j2,/etc/frr/zebra.conf \
        -t /usr/share/sonic/templates/staticd/gen_staticd.conf.j2,/etc/frr/staticd.conf \
        -t /usr/share/sonic/templates/sharpd/sharpd.conf.j2,/etc/frr/sharpd.conf \
    "
    MGMT_FRAMEWORK_CONFIG=$(echo $FRR_VARS | jq -r '.frr_mgmt_framework_config')
    if [ -n "$MGMT_FRAMEWORK_CONFIG" ] && [ "$MGMT_FRAMEWORK_CONFIG" != "false" ]; then
        CFGGEN_PARAMS=" \
            -d \
            -y /etc/sonic/constants.yml \
            -T /usr/local/sonic/frrcfgd \
            -t /usr/share/sonic/templates/gen_frr.conf.j2,/etc/frr/frr.conf \
        "
        sonic-cfggen $CFGGEN_PARAMS
        echo "service integrated-vtysh-config" > /etc/frr/vtysh.conf
        rm -f /etc/frr/bgpd.conf /etc/frr/zebra.conf /etc/frr/staticd.conf \
              /etc/frr/bfdd.conf /etc/frr/ospfd.conf /etc/frr/pimd.conf \
              /etc/frr/sharpd.conf
    else
        rm -f /etc/frr/bfdd.conf /etc/frr/ospfd.conf
        sonic-cfggen $CFGGEN_PARAMS
        echo "no service integrated-vtysh-config" > /etc/frr/vtysh.conf
        rm -f /etc/frr/frr.conf
    fi
elif [ "$CONFIG_TYPE" == "split" ]; then
    echo "no service integrated-vtysh-config" > /etc/frr/vtysh.conf
    rm -f /etc/frr/frr.conf
    write_default_zebra_config /etc/frr/zebra.conf
elif [ "$CONFIG_TYPE" == "split-unified" ]; then
    echo "service integrated-vtysh-config" > /etc/frr/vtysh.conf
    rm -f /etc/frr/bgpd.conf /etc/frr/zebra.conf /etc/frr/staticd.conf \
          /etc/frr/sharpd.conf
    write_default_zebra_config /etc/frr/frr.conf
elif [ "$CONFIG_TYPE" == "unified" ]; then
    CFGGEN_PARAMS=" \
        -d \
        -y /etc/sonic/constants.yml \
        -T /usr/local/sonic/frrcfgd \
        -t /usr/share/sonic/templates/gen_frr.conf.j2,/etc/frr/frr.conf \
    "
    sonic-cfggen $CFGGEN_PARAMS
    echo "service integrated-vtysh-config" > /etc/frr/vtysh.conf
    rm -f /etc/frr/bgpd.conf /etc/frr/zebra.conf /etc/frr/staticd.conf \
          /etc/frr/bfdd.conf /etc/frr/ospfd.conf /etc/frr/pimd.conf \
          /etc/frr/sharpd.conf
fi

chown -R frr:frr /etc/frr/

# Create sr0 interface for SRv6 support
if ! ip link show sr0 > /dev/null 2>&1; then
    echo "Interface sr0 does not exist. Creating sr0..."
    ip link add sr0 type dummy || true
else
    echo "Interface sr0 already exists."
fi
ip link set sr0 up || true

chown root:root /usr/sbin/bgp-isolate
chmod 0755 /usr/sbin/bgp-isolate

chown root:root /usr/sbin/bgp-unisolate
chmod 0755 /usr/sbin/bgp-unisolate

mkdir -p /var/sonic
echo "# Config files managed by sonic-config-engine" > /var/sonic/config_status

if pgrep -x pebble > /dev/null 2>&1; then
    LAYER_FILE="/usr/share/sonic/templates/syslog-layer.yaml"
    pebble add syslog-layer --combine $LAYER_FILE
    pebble replan

    sonic-cfggen -d -y /etc/sonic/constants.yml \
        -t /usr/share/sonic/templates/pebble-layer.j2 > /tmp/frr-layer.yaml
    pebble add frr-layer --combine /tmp/frr-layer.yaml
    pebble replan

    pebble start mgmtd
    pebble start zebra

    # zsocket is a one-shot that verifies zebra's zapi socket is ready;
    # staticd/bgpd wait for it to exit (dependent_startup_wait_for=zsocket:exited).
    pebble start zsocket
    while pebble services zsocket 2>/dev/null | grep -q '^zsocket.*active'; do sleep 1; done

    pebble start staticd
    pebble start bgpd

    for svc in bfdd ospfd pimd pathd fpmsyncd frrcfgd bgpcfgd bgpmon staticroutebfd bfdmon vtysh_b bgp_eoiu_marker sharpd; do
        if pebble services "$svc" 2>/dev/null | grep -q "^$svc "; then
            pebble start "$svc" || true
        fi
    done
fi
```

## Task 4: build-integration edits

1. `build_rocks.sh` rocklist — after `"dockers/docker-nat"`, append `    "dockers/docker-fpm-frr"`.
2. `rules/docker-fpm-frr.dep` — replace `DEP_FILES   += $(shell git ls-files $(DPATH))` with:
   ```
   DEP_FILES   += $(filter-out $(DPATH)/rockcraft.yaml,$(shell git ls-files $(DPATH)))
   ```

## Verification

Run §11.1 (skip: `.gz` exists) → §11.2 `./build_rocks.sh` (frr rock packs + loads) → §11.3 on failure → §11.4 bare-machine runtime → §11.5 vs image repack → §11.6 full runtime (QEMU VM, inventory, pebble states, logs, harness).