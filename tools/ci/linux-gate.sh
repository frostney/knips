#!/usr/bin/env bash
#
# linux-gate.sh — what "knips works on Linux" means today.
#
# Runs inside the tools/ci/Dockerfile.linux container, from a copy of the
# checkout at /work. Invoked by tools/linux-ci.sh; not meant to be run on a
# developer's Mac (it would build an ELF binary over build/knips).
#
# The gate is deliberately separate claims, each provable on its own:
#   1. the platform-neutral suites pass on Linux (ADR-0004's promise);
#   2. `lwpt build` produces a Linux binary — knips.pas already has a
#      non-Darwin branch, so the CLI shell and the MCP server compile;
#   3. that binary behaves: it prints its version, and the capture
#      subcommands refuse in-band with exit 3 rather than crashing;
#   4. the formatter agrees on Linux as well as on a Mac;
#   5. the X11/MIT-SHM capture spike grabs a verified frame off Xvfb and
#      writes it through the neutral GIF encoder.
#
# Anything that needs a compositor, a portal or a hardware encoder is out of
# scope here — see docs/ports.md, "What this Mac can prove".

set -euo pipefail

step() { printf '\n===== %s =====\n' "$1"; }

step 'toolchain'
uname -srm
fpc -iV
lwpt --version

step 'lwpt test (platform-neutral suites)'
lwpt test

step 'lwpt build (Linux binary)'
lwpt build
file build/knips || true

step 'binary smoke'
./build/knips --version

# knips and `knips mcp` must start on a machine with no X11 at all: the X11
# libraries are opened at run time by `record` (ADR-0006), never linked.
if ldd build/knips | grep -E 'libX11|libXext'; then
  echo "linux-gate: build/knips links X11 at load time; ADR-0006 forbids it" >&2
  exit 1
fi
echo "build/knips links no X11 library"

# What Linux cannot record is refused with ExitUnsupported (3), not a crash
# and not a silent success. Movies are the one the gate pins here.
set +e
./build/knips record --out=/tmp/knips-linux-gate.mp4 >/tmp/knips-record.out 2>&1
record_rc=$?
set -e
cat /tmp/knips-record.out
if [ "$record_rc" -ne 3 ]; then
  echo "linux-gate: expected exit 3 (unsupported) from 'record', got $record_rc" >&2
  exit 1
fi
echo "record refused with exit 3, as expected"

step 'lwpt format --check'
lwpt format --check

# The X11/MIT-SHM capture spike: a real frame off a real (virtual) X server,
# straight into the platform-neutral GIF encoder. This is the part of a Linux
# recorder that can be proven without a Linux machine — see docs/ports.md.
#
# It is compiled with `fpc @lwpt.cfg` (the one direct-compiler form AGENTS.md
# sanctions) rather than an lwpt build entry, because a Linux-only entry would
# fail `lwpt build` on macOS.
step 'x11 capture spike (Xvfb)'
Xvfb :99 -screen 0 1024x768x24 -nolisten tcp &
xvfb_pid=$!
trap 'kill "$xvfb_pid" 2>/dev/null || true' EXIT
export DISPLAY=:99

# Wait for the server rather than guessing at a sleep.
for _ in $(seq 1 50); do
  if xdpyinfo >/dev/null 2>&1; then break; fi
  sleep 0.2
done
# sed rather than head: head closes the pipe early, and under `set -o
# pipefail` the SIGPIPE that produces is a fatal 141.
xdpyinfo | sed -n '1,4p'

mkdir -p build/x11spike/units
fpc @lwpt.cfg \
  -Fusource/capture-linux -Fisource/capture-linux \
  -FUbuild/x11spike/units -FEbuild/x11spike \
  -oknips-x11-spike \
  source/capture-linux/knips-x11-spike.pas

# --paint asks the spike to fill the root with a known colour and then check
# every captured pixel against it, so a channel-order mistake fails here
# rather than looking like a successful capture.
./build/x11spike/knips-x11-spike \
  --display=:99 --size=320x200 --paint=3366cc \
  --out=build/x11spike/frame.gif

if [ ! -s build/x11spike/frame.gif ]; then
  echo "linux-gate: the spike wrote no GIF" >&2
  exit 1
fi
file build/x11spike/frame.gif

# knips record itself: a real take off the same Xvfb, stopped with SIGINT the
# way a user's Ctrl-C would, must leave a finished APNG and no temporary.
step 'knips record --out=*.apng (Xvfb)'
rm -f build/x11spike/take.apng
./build/knips record --out=build/x11spike/take.apng --rect=0,0,320,200 \
  --no-cursor &
record_pid=$!
sleep 2
kill -INT "$record_pid"
wait "$record_pid"
if [ "$(head -c 8 build/x11spike/take.apng | od -An -c | tr -d ' ')" != '211PNG\r\n032\n' ]; then
  echo "linux-gate: take.apng does not start with the PNG signature" >&2
  exit 1
fi
if ! grep -q acTL build/x11spike/take.apng; then
  echo "linux-gate: take.apng has no acTL chunk, so it is not animated" >&2
  exit 1
fi
if ls build/x11spike/*.knips-recording-*.tmp >/dev/null 2>&1; then
  echo "linux-gate: a finished take left its temporary behind" >&2
  exit 1
fi
file build/x11spike/take.apng

step 'linux gate: ok'
