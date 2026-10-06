# docker-dhcp-server Rockcraft + Pebble Migration Plan (Resolute)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans or superpowers:subagent-driven-development.
>
> Parent spec: `2026-07-27-rockcraft-pebble-resolute-containers-migration-meta-spec-en.md` (section refs below; §9.11 is this container). Closest siblings: `dockers/docker-dhcp-relay` (same wheel `sonic_dhcp_utilities`, config-engine base, `IMAGE_VERSION` consumer) and `dockers/docker-fpm-frr` (gate polling from start.sh).

**Goal:** Migrate `docker-dhcp-server` (container `dhcp_server`) from Dockerfile + supervisord to Rockcraft + Pebble on `202605_resolute_rock`, Docker path coexisting, and pass §11.

**Architecture:** Approach A (§7.1). `rockcraft.yaml` declares `rsyslogd`, `start`, `dhcpservd`, `kea-dhcp4`; the last two have no `startup:` key. `start.sh`'s pebble branch does what `docker_init.sh` did, starts `dhcpservd`, runs the `dhcpservd-ready` gate inline, then starts `kea-dhcp4`.

**Tech Stack:** rockcraft (ubuntu@26.04), pebble, bash, kea-dhcp4-server (Ubuntu archive 3.0.3).

## Global Constraints

- `base: ubuntu@26.04`, `build-base: ubuntu@26.04`; stage-packages by package name; SONiC debs via `dpkg -x debs/<pkg>_*.deb`.
- No supervisord in the rock; no service `environment:` except the one justified in §9.11 (`KEA_PIDFILE_DIR=/tmp/` on `kea-dhcp4`).
- `Dockerfile.j2`, `supervisord.conf`, `critical_processes`, `docker_init.sh`, `rules/docker-dhcp-server.mk` unchanged (§10.3). Native-image install (§4.2 step 2) is already the case in the `.mk` (`SONIC_INSTALL_DOCKER_IMAGES`, gated by `INCLUDE_DHCP_SERVER`).
- `.dep` filters out `rockcraft.yaml` (§4.2). No `pebble-layer.j2` (approach A).
- `start.sh` consumes `IMAGE_VERSION` -> copy `envs` in `override-prime` and `source` it (§3.2).
- Quick one-shots run inline, not as pebble services (§6).

## Environment notes (verified 2026-10-03)

- Local `202605_resolute_rock` == origin == PR #9 head `89a944a6d`; 16 `rockcraft.yaml` in `dockers/` + `platform/`; dhcp-relay is being migrated in the same worktree (uncommitted: `build_rocks.sh` relay line, `docker-dhcp-relay/*`, `rules/docker-dhcp-relay.dep`) -- do not touch those hunks.
- `INCLUDE_DHCP_SERVER` defaults to `n` (`rules/config:206`); `rules/config.user` (gitignored) now sets `INCLUDE_DHCP_SERVER = y`.
- **No baseline switch**: neither `et3-dh3-f-sw1` nor `dut2` has dhcp-server (no image, no feature). Per §8, proceed without it. The Docker-path image built locally (`make target/docker-dhcp-server.gz`) is the baseline instead.
- Docker image facts: `kea-dhcp4-server` (+ `kea-common`, which ships `libdhcp_run_script.so`, found at runtime by `find / -name libdhcp_run_script.so` in `dhcpservd`), `tcpdump`, pip `psutil`/`freezegun`/`sonic-dhcp-utilities`; `_kea` user/group from `kea-common` postinst; `lease_update.sh` is mode 644 in git, `docker_init.sh` `chmod +x`'s it.
- `psutil` has a `cp36-abi3` manylinux wheel for py3.14, so §9.11's `python3-dev`+`build-essential` build-packages are expected to be unnecessary (verify by removal).

## supervisord -> pebble translation (container-wide view, §5.2)

| supervisord | pebble |
|---|---|
| `rsyslogd` (dependent_startup) | `startup: enabled` |
| `start` (waits rsyslogd:running, exits) | `startup: enabled`, `on-success/on-failure: ignore` |
| `dhcpservd` (waits start:exited) | service, no `startup`; `pebble start dhcpservd` after start.sh's own init |
| `dhcpservd-ready` (waits dhcpservd:running, <=120s gate) | **inline** `/usr/bin/wait_for_dhcpservd.sh` in start.sh (a pebble service would fail the <1s-exit rule) |
| `kea-dhcp4` (waits dhcpservd-ready:exited, `KEA_PIDFILE_DIR=/tmp/`) | service with `environment:`; `pebble start kea-dhcp4` after the gate (regardless of gate exit code, as supervisord only waits for EXITED) |
| listeners, `critical_processes`, group | dropped (supervisord-only, same as other rocks) |
| `docker_init.sh` mkdirs / chmod / `rm -f /tmp/dhcpservd_ready` | start.sh pebble branch |
| `docker_init.sh` `chmod +x` | `chmod +x lease_update.sh` in `override-build`; other scripts already 755 in git |

## Files

- Create: `dockers/docker-dhcp-server/rockcraft.yaml`
- Modify: `dockers/docker-dhcp-server/start.sh`, `build_rocks.sh` (uncomment `"dockers/docker-dhcp-server"`), `rules/docker-dhcp-server.dep`

---

## Task 1: rock sources

- [ ] Create `dockers/docker-dhcp-server/rockcraft.yaml` (config-engine skeleton §5 + container specifics):
  - services: `rsyslogd`, `start`, `dhcpservd` (`/usr/bin/dhcpservd`; confirm entry-point path after build), `kea-dhcp4` (`/usr/sbin/kea-dhcp4 -c /etc/kea/kea-dhcp4.conf`, `environment: KEA_PIDFILE_DIR: /tmp/`).
  - `setup-dhcp-server`: same 7 config-engine debs as dhcp-relay; `organize` start.sh, wait_for_dhcpservd.sh, `kea-dhcp4.conf.j2`, `lease_update.sh` -> `etc/kea/`, `kea-dhcp4-init.conf` -> `etc/kea/kea-dhcp4.conf` (`(overwrite)`, the `kea-dhcp4-server` package ships a default there), common `files/*`.
  - stage-packages: skeleton base list + `python3-cffi-backend` (python3-libyang) + `libpython3.14` + `kea-dhcp4-server` + `tcpdump` (both from the Dockerfile).
  - `install-python`: config-engine wheels + `sonic_dhcp_utilities` + `jinjanator click pyangbind==0.8.7 lxml psutil`; `organize` yang-models (§5.3).
  - `add-user`: `syslog` only (try without `_kea`; kea runs as root, as in the Docker path).
- [ ] Modify `start.sh`: guarded `source envs`; append pebble branch (mkdir `/etc/kea /run/kea /var/log/kea /var/lib/kea`, `chmod 750 /run/kea`, `rm -f /tmp/dhcpservd_ready`, syslog layer, `pebble start dhcpservd`, `wait_for_dhcpservd.sh`, `pebble start kea-dhcp4`).

## Task 2: build integration

- [ ] `build_rocks.sh`: uncomment `"dockers/docker-dhcp-server"`.
- [ ] `rules/docker-dhcp-server.dep`: `DEP_FILES += $(filter-out $(DPATH)/rockcraft.yaml,$(shell git ls-files $(DPATH)))`.

## Task 3: verify

- [ ] §11.1 `make target/docker-dhcp-server.gz` (done above, Docker image loads).
- [ ] §11.2 `./build_rocks.sh` -> `target/docker-dhcp-server.gz` rock, `docker load` OK. (Build only this rock; see Execution notes.)
- [ ] §11.3 pack errors: fix by dependency (missing `.so` -> stage-packages).
- [ ] §11.4 bare-machine run: `docker ps` alive, `pebble services` (rsyslogd active, start inactive), `pebble logs` free of defect markers; `ldd` check on `kea-dhcp4`; `find / -name libdhcp_run_script.so`; try removing `python3-dev`/`build-essential` and `_kea`.
- [ ] §11.5 `make target/sonic-vs.img.gz` does not overwrite the rock gz (birth time unchanged).
- [ ] §11.6 boot VS image, `sudo config feature state dhcp_server enabled`, check `azure-labels=0`, `pebble services/changes/health/logs`, expected state: rsyslogd, dhcpservd, kea-dhcp4 active; start inactive.

## Execution notes

- `build_rocks.sh` loops over the whole rocklist; to build only dhcp-server, run it with a temporary rocklist copy outside the repo rather than editing the shared script or touching dhcp-relay's in-progress entry.

## Results (2026-10-03)

- Rock packs (`rockcraft pack`) and loads; §11.5 passed (`target/docker-*.gz` birth times unchanged after `make target/sonic-vs.img.gz`); VS image boots and shows `dhcp_server` in `show feature status` (disabled by default -> `sudo config feature state dhcp_server enabled`). `azure-labels=0`.
- Deviations from the plan, found by experiment:
  - `organize` has no `(overwrite)` syntax (value is taken as a literal path, creating `/(overwrite)etc/...`); `kea-dhcp4-init.conf` is `cp`'d in `override-prime` instead, plus `-kea-dhcp4-init.conf` in `prime`.
  - `python3-dev`/`build-essential` removed: psutil installs from its `cp36-abi3` binary wheel (pip log: `Downloading psutil-7.2.2-cp36-abi3-manylinux...whl`). §9.11's note on this is stale on py3.14.
  - `_kea` user not needed (kea runs as root, same as the Docker path).
- **Pre-existing defect, FIXED below: `kea-dhcp4` could not start on Resolute.** Kea 3.0.3's `libdhcp_run_script.so` only accepts scripts under `/usr/share/kea/scripts` (`RUN_SCRIPT_LOAD_ERROR ... invalid path specified: '/etc/kea', supported path is '/usr/share/kea/scripts'`), but `dhcpservd` hardcodes `/etc/kea/lease_update.sh` (`dhcp_cfggen.py:24`). Reproduced on a plain `ubuntu:26.04` + `kea-dhcp4-server` with the generated config, so it is identical on the Docker path. In the VM `start` ends in pebble `error` and `kea-dhcp4` in `backoff` because of it.
  - Verified workaround (VM-only, not committed): copy `lease_update.sh` to `/usr/share/kea/scripts/` and point `LEASE_UPDATE_SCRIPT_PATH` there -> `dhcpservd`, `kea-dhcp4`, `rsyslogd` active, `start` inactive, all changes `Done`, `pebble health` healthy, no defect markers in logs.
  - Real fix touches shared files (`src/sonic-dhcp-utilities` constant + tests, `Dockerfile.j2` COPY destination, rock `organize`), i.e. beyond the §10.3 "unmodified" list -> needs a decision.

## kea-dhcp4 fix (2026-10-05)

Moved the run_script hook script to Kea 3.0's only accepted directory, in both paths:
- `src/sonic-dhcp-utilities/dhcp_utilities/dhcpservd/dhcp_cfggen.py`: `LEASE_UPDATE_SCRIPT_PATH = "/usr/share/kea/scripts/lease_update.sh"`; tests (`conftest.py`, `test_dhcp_cfggen.py`, `test_smart_switch.py`) updated to the same path.
- `dockers/docker-dhcp-server/Dockerfile.j2` COPY destination and `docker_init.sh` `chmod +x` path (Docker path).
- `dockers/docker-dhcp-server/rockcraft.yaml` `organize: lease_update.sh: usr/share/kea/scripts/lease_update.sh`.

Verified: wheel build runs the unit tests (388 passed); Docker-path image: kea loads the hook and reaches `DHCP4_STARTED`; rock in the VS VM: `dhcpservd`/`kea-dhcp4`/`rsyslogd` active, `start` inactive, all pebble changes Done, healthy, `RUN_SCRIPT_LOAD` in kea log. `make` does not track `src/` timestamps: delete the wheel/`docker-*.gz` (+ `.log`) to force a rebuild. Helper scripts: `tools/build_one_rock.sh`, `tools/vm.sh`.
