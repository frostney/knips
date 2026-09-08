#!/usr/bin/env bash
#
# The Definition of Done, as a command.
#
# DEFINITION_OF_DONE.md used to list these as prose and nothing ran them
# in order, so "did the release gate pass?" was a question answered from
# memory. They run here, in the order that makes a failure cheap: the
# formatter first (a second), then the dev build, then the suites, then
# the generated-block check, then the release build, and only then the
# probe against the release binary — which is the one that needs a Mac
# with Screen Recording permission and is therefore the one worth
# reaching last.
#
#   tools/release-gate.sh              every gate
#   tools/release-gate.sh --no-probe   everything a machine with no
#                                      display, or no permission, can do
#
# `lwpt agents --check` is in here and not only in the pre-push hook: a
# release must not ship an AGENTS.md whose generated block describes a
# toolchain surface that has moved, and the Definition of Done calls that
# block a gate.
#
# **This script leaves build/knips a RELEASE binary** when the probe runs
# — the release build is the last thing that writes it. Run `lwpt build`
# afterwards to get the dev binary back; a release binary is fine to
# ship and confusing to debug against.
#
# The dev-mode probe is deliberately NOT here. This gate is about the
# artefact that ships; the dev build's own probe belongs to the ordinary
# edit loop. Point KNIPS_LWPT at another lwpt binary to override the one
# on PATH, exactly as lefthook.yml does.

set -u

LWPT="${KNIPS_LWPT:-lwpt}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE=1

for argument in "$@"; do
  case "$argument" in
    --no-probe) PROBE=0 ;;
    -h|--help)
      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "release-gate: unknown option $argument" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT" || exit 1

step=0
run() {
  step=$((step + 1))
  echo "== release gate $step/$total: $* =="
  "$@"
  local status=$?
  if [ $status -ne 0 ]; then
    echo "release-gate: FAILED at step $step: $*" >&2
    exit $status
  fi
}

if [ $PROBE -eq 1 ]; then
  total=6
else
  total=4
fi

run "$LWPT" format --check
run "$LWPT" build
run "$LWPT" test
# The generated block at the end of AGENTS.md. Stale means the file
# describes a toolchain surface that has moved, which is the one kind of
# documentation an agent reads as fact.
run "$LWPT" agents --check

if [ $PROBE -eq 1 ]; then
  run "$LWPT" build --mode release
  # -O4 turns on field reordering that dev builds never exercise; an
  # alignment bug it exposed shipped crash-free in dev mode from the
  # first on-device commit. The release binary is what has to probe.
  run ./build/knips probe
fi

echo "release-gate: all $total gate(s) passed"
if [ $PROBE -eq 1 ]; then
  echo "release-gate: build/knips is now a RELEASE binary; run \`$LWPT build\` to get the dev one back"
fi
