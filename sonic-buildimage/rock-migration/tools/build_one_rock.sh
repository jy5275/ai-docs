#!/usr/bin/env bash
# Build ONE rock with the repo's build_rocks.sh logic (rocklist replaced by the given item).
# Usage: cd <sonic-buildimage> && build_one_rock.sh dockers/docker-xxx
# The platform-specific rocklist+= branch is disabled so ONLY the given rock is built.
# Needs: rockcraft, sudo, docker, pigz; target/{debs,files,python-wheels}/resolute populated.
set -e
item="$1"; tmp=$(mktemp /tmp/build_rocks_one.XXXXXX.sh)
awk -v item="$item" '
  /^rocklist=\(/ {print "rocklist=(\n    \"" item "\"\n)"; skip=1; next}
  skip && /^\)/ {skip=0; next}
  skip {next}
  {print}' build_rocks.sh | sed 's|^if \[ "$(cat .platform.*|if false; then|' > "$tmp"
bash "$tmp"; rm -f "$tmp"
