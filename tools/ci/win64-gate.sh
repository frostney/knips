#!/usr/bin/env bash
#
# win64-gate.sh — "does knips compile and link for x86_64-win64".
#
# Runs inside the tools/ci/Dockerfile.win64 container, from a copy of the
# checkout at /work. Invoked by tools/win64-cross.sh.
#
# lwpt has no cross-target build entry, and lwpt.cfg/lwpt.lock are generated
# and must not be hand-edited, so this uses the one form AGENTS.md sanctions
# for reaching the compiler directly: `fpc @lwpt.cfg`. Every unit and include
# path still comes from the generated lwpt.cfg — the only things added here
# are the target selector and the output directories.
#
# What it proves: the platform-neutral core and the CLI shell produce a
# linked PE/COFF executable for 64-bit Windows. What it does not prove: that
# any of it behaves on Windows. Nothing here touches a Windows API — the
# Windows backend does not exist yet (see docs/ports.md). Running the
# artefacts belongs to tools/wine-smoke.sh, not here.

set -euo pipefail

out=build/win64
units=$out/units
rm -rf "$out"
mkdir -p "$units"

printf '\n===== cross toolchain =====\n'
fpc -Twin64 -Px86_64 -iW -iTO -iTP

# knips.pas first: it is the whole program, and its non-Darwin branch is what
# a Windows build would grow into. The suites follow, because between them
# they reach every platform-neutral unit in the tree.
targets=(source/knips.pas)
for t in source/*.Test.pas; do targets+=("$t"); done

failed=0
for src in "${targets[@]}"; do
  base=$(basename "$src" .pas)
  printf '\n----- %s -----\n' "$src"
  set +e
  fpc -Twin64 -Px86_64 @lwpt.cfg \
    -FU"$units" -FE"$out" -o"$base.exe" \
    "$src"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "win64-gate: FAILED to build $src (exit $rc)" >&2
    failed=1
    continue
  fi
  if [ ! -f "$out/$base.exe" ]; then
    echo "win64-gate: $src compiled but produced no $out/$base.exe" >&2
    failed=1
    continue
  fi
  file "$out/$base.exe"
done

if [ "$failed" -ne 0 ]; then
  echo "win64-gate: one or more targets failed" >&2
  exit 1
fi

printf '\n===== produced =====\n'
ls -l "$out"/*.exe

# Every artefact must actually be a 64-bit Windows executable, not something
# the host toolchain quietly produced instead.
printf '\n===== PE/COFF check =====\n'
for exe in "$out"/*.exe; do
  desc=$(file -b "$exe")
  case "$desc" in
    *"PE32+"*"x86-64"*) echo "ok: $(basename "$exe") — $desc" ;;
    *) echo "win64-gate: $(basename "$exe") is not a 64-bit PE: $desc" >&2; exit 1 ;;
  esac
done

# Running the artefacts is deliberately not this script's job. A gate that
# reports "did not run cleanly" and carries on is not a gate, and the image
# this runs in has no Wine anyway. tools/wine-smoke.sh owns that, propagates
# the suites' exit codes, and is where a Windows-behaviour failure belongs.

printf '\n===== win64 gate: ok =====\n'
