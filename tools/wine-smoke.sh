#!/usr/bin/env bash
#
# wine-smoke.sh — run the cross-built Windows binaries under Wine.
#
# 1. Runs tools/ci/win64-gate.sh in the cross-compile container, extracting
#    the .exe files into build/win64/ on this machine (build/ is ignored).
# 2. Runs them in an amd64 Wine container: `knips.exe --version`, then every
#    neutral suite.
#
# This is a bonus, not a gate. Wine is not Windows; a failure here is worth
# investigating and a pass here is not a Windows guarantee. What it does catch
# cheaply is Windows-shaped behaviour the compiler cannot see — path
# separators, drive letters, line endings.
#
# Exits non-zero if any suite fails, so a gate can be built on it later.
#
# Usage:  tools/wine-smoke.sh

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
out="$root/build/win64"

echo "==> cross-building for win64"
docker build \
  -f "$root/tools/ci/Dockerfile.win64" \
  -t knips-win64-cross:native \
  "$root/tools/ci"

rm -rf "$out"
mkdir -p "$out"
docker run --rm \
  -v "$root:/src:ro" \
  -v "$out:/out" \
  -w /work \
  knips-win64-cross:native \
  bash -eu -o pipefail -c '
    tar -C /src --exclude=./.git --exclude=./build --exclude=./.lwpt/sessions -cf - . \
      | tar -C /work -xf -
    bash tools/ci/win64-gate.sh
    cp build/win64/*.exe /out/
  '

echo "==> building the Wine image"
docker build --platform linux/amd64 \
  -f "$root/tools/ci/Dockerfile.wine" \
  -t knips-wine:amd64 \
  "$root/tools/ci"

echo "==> running under Wine"
docker run --rm --platform linux/amd64 \
  -v "$out:/exe:ro" \
  knips-wine:amd64 \
  bash -eu -c '
    cp /exe/*.exe /work/
    cd /work
    wine --version
    echo "--- knips.exe --version"
    wine knips.exe --version
    fails=0
    for exe in *.Test.exe; do
      echo "--- $exe"
      if wine "$exe"; then
        :
      else
        echo "wine-smoke: FAILED $exe"
        fails=$((fails + 1))
      fi
    done
    echo "wine-smoke: $fails suite(s) failed"
    [ "$fails" -eq 0 ]
  '
