#!/usr/bin/env bash
# Pull every image the rig needs (arm64) so the demo runs with Wi-Fi off.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
for img in $(cat images-*.txt | grep -v '^#' | grep -v '^$'); do
  if docker image inspect "$img" >/dev/null 2>&1; then echo "have  $img"; continue; fi
  echo "pull  $img"
  docker pull --platform linux/arm64 -q "$img" >/dev/null || { echo "FAIL  $img"; fail=1; }
done
exit $fail
