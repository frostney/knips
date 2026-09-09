#!/usr/bin/env bash
# Synthetic macOS integration checks; no screen/camera capture or permissions.
# Requires build/knips, ffmpeg, ffprobe, Python 3, rg and the pinned FPC.
# Run from any directory: tools/check-file-safety.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ "$(uname -s)" = Darwin ] || { echo 'file-safety: requires macOS' >&2; exit 1; }
for tool in ffmpeg ffprobe python3 fpc rg; do
  command -v "$tool" >/dev/null
done
[ -x build/knips ] || { echo 'file-safety: run lwpt build first' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/knips-file-safety.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { echo "file-safety: $*" >&2; exit 1; }
render() {
  local output="$1"
  shift
  if ! ./build/knips render --in="$WORK/source.mp4" --out="$output" \
      --effects=smooth-cursor "$@" >"$WORK/render.out" 2>"$WORK/render.err"; then
    cat "$WORK/render.out" "$WORK/render.err" >&2
    fail 'render failed unexpectedly'
  fi
}

ffmpeg -nostdin -v error -f lavfi -i 'testsrc2=size=64x48:rate=30:duration=1' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1' \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$WORK/source.mp4"
python3 - "$WORK" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
dead_pid = 2147483647
try:
    os.kill(dead_pid, 0)
except ProcessLookupError:
    pass
else:
    raise SystemExit('fixture PID unexpectedly exists')
header = dict(k='header', format='knips-events', version=1, knips='fixture',
    movie='source.mp4', created='2026-09-09T00:00:00Z', pid=dead_pid,
    target='display', pixelWidth=64, pixelHeight=48, scale=1, fps=30,
    sampleHz=30, displayId=1, displayWidth=64, displayHeight=48,
    baseX=0, baseY=0, baseWidth=64, baseHeight=48, menuBarInset=0,
    cursor='smooth', bakedZoomOnClick=False, bakedFollowMouse=False,
    bakedWindowFollow=False, audio='system')
records = [header, dict(k='anchor', host=1)]
records += [dict(k='cursor', t=1 + i / 30, x=8 + i, y=20, b=0)
            for i in range(31)]
records += [dict(k='trailer', t=2, frames=30, duration=1, samples=31)]
(root / 'source.knips.jsonl').write_text(''.join(
    json.dumps(record, separators=(',', ':')) + '\n' for record in records))
PY
cp "$WORK/source.mp4" "$WORK/source.before"
cp "$WORK/source.knips.jsonl" "$WORK/sidecar.before"

# A normal render exercises the encoded video and passthrough audio paths.
render "$WORK/normal.mp4"
ffprobe -v error -show_streams -show_format -of json "$WORK/normal.mp4" \
  >"$WORK/probe.json"
python3 - "$WORK" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
probe = json.loads((root / 'probe.json').read_text())
video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
audio = next(s for s in probe['streams'] if s['codec_type'] == 'audio')
assert (video['width'], video['height']) == (64, 48), video
assert video['codec_name'] == 'h264', video
assert audio['codec_name'] == 'aac', audio
assert 0.9 <= float(probe['format']['duration']) <= 1.2, probe
assert (root / 'normal.knips.jsonl').is_file()
PY
ffmpeg -nostdin -v error -i "$WORK/normal.mp4" -f null -
echo 'PASS normal render retains decodable video and audio'

# A different container with the same stem still aliases the input sidecar.
if ./build/knips render --in="$WORK/source.mp4" --out="$WORK/source.mov" \
    --effects=smooth-cursor >"$WORK/alias.log" 2>&1; then
  fail 'same-stem output was accepted'
fi
rg -q 'sidecar|same file' "$WORK/alias.log"
cmp "$WORK/source.mp4" "$WORK/source.before"
cmp "$WORK/source.knips.jsonl" "$WORK/sidecar.before"
[ ! -e "$WORK/source.mov" ] || fail 'same-stem refusal wrote a movie'
echo 'PASS same-stem refusal preserves the take and metadata'

# The final sidecar must never truncate a symlink target.
printf '%s\n' 'sidecar victim' >"$WORK/victim"
cp "$WORK/victim" "$WORK/victim.before"
ln -s "$WORK/victim" "$WORK/linked.knips.jsonl"
render "$WORK/linked.mp4"
cmp "$WORK/victim" "$WORK/victim.before"
[ -L "$WORK/linked.knips.jsonl" ] || fail 'sidecar symlink was replaced'
[ -s "$WORK/linked.mp4" ] || fail 'movie missing after sidecar refusal'
rg -q 'sidecar.*(could not|symbolic link|refus)' "$WORK/render.err"
echo 'PASS sidecar symlink target survives with a visible warning'

mkdir "$WORK/blocked.knips.jsonl"
render "$WORK/blocked.mp4"
[ -s "$WORK/blocked.mp4" ] || fail 'movie missing after blocked sidecar'
[ -d "$WORK/blocked.knips.jsonl" ] || fail 'sidecar directory was replaced'
rg -q 'sidecar.*could not' "$WORK/render.err"
echo 'PASS sidecar failure retains the movie and emits a warning'

# MCP reports the same partial success in both content and structured data.
mkdir "$WORK/mcp-blocked.knips.jsonl"
python3 - "$WORK" <<'PYMCP'
import json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
output = root / 'mcp-blocked.mp4'
requests = [
    dict(jsonrpc='2.0', id=1, method='initialize', params=dict(
        protocolVersion='2025-06-18', capabilities={},
        clientInfo=dict(name='file-safety-check', version='1'))),
    dict(jsonrpc='2.0', method='notifications/initialized'),
    dict(jsonrpc='2.0', id=2, method='tools/call', params=dict(
        name='render', arguments={'in': str(root / 'source.mp4'),
            'out': str(output), 'cursor': 'smooth', 'zoom': False})),
]
process = subprocess.run(['./build/knips', 'mcp'], text=True,
    input=''.join(json.dumps(request) + '\n' for request in requests),
    capture_output=True, timeout=60, check=True)
responses = [json.loads(line) for line in process.stdout.splitlines() if line]
response = next(item for item in responses if item.get('id') == 2)
assert 'error' not in response, response
result = response['result']
assert not result.get('isError', False), result
structured = result['structuredContent']
assert structured['path'] == str(output), structured
assert structured['bytes'] == output.stat().st_size > 0, structured
assert structured.get('sidecar_error'), structured
assert 'sidecar_path' not in structured, structured
summary = '\n'.join(item.get('text', '') for item in result['content'])
assert 'movie saved' in summary, summary
assert (root / 'mcp-blocked.knips.jsonl').is_dir()
PYMCP
echo 'PASS MCP reports saved movie bytes and sidecar failure without a false path'

# An early render failure must not sweep another operation's old fixed name.
printf '%s\n' 'live temporary' >"$WORK/live.mp4.knips-render-tmp"
printf '%s\n' "$$" >"$WORK/live.mp4.knips-render-tmp.pid"
cp "$WORK/live.mp4.knips-render-tmp" "$WORK/live.before"
cp "$WORK/live.mp4.knips-render-tmp.pid" "$WORK/pid.before"
if ./build/knips render --in="$WORK/missing.mp4" --out="$WORK/live.mp4" \
    --effects=smooth-cursor >"$WORK/invalid.log" 2>&1; then
  fail 'missing input render was accepted'
fi
cmp "$WORK/live.mp4.knips-render-tmp" "$WORK/live.before"
cmp "$WORK/live.mp4.knips-render-tmp.pid" "$WORK/pid.before"
echo 'PASS invalid render preserves live scratch and its owner marker'

# Final publication can fail after a complete copy or encoded render exists.
# Both paths must release their own scratch without touching the live fixture.
for effect in none smooth-cursor; do
  output="$WORK/failed-$effect.mp4"
  mkdir "$output"
  if ./build/knips render --in="$WORK/source.mp4" --out="$output" \
      --effects="$effect" >"$WORK/commit-$effect.log" 2>&1; then
    fail 'render accepted a directory as its final output'
  fi
  rg -q 'could not replace' "$WORK/commit-$effect.log"
  [ -d "$output" ] || fail 'failed publication changed the destination'
  python3 - "$WORK" "$effect" <<'PY'
import pathlib, sys
root, effect = pathlib.Path(sys.argv[1]), sys.argv[2]
leftovers = list(root.glob('*-failed-' + effect + '.mp4.knips-render-tmp*'))
assert not leftovers, leftovers
PY
  cmp "$WORK/live.mp4.knips-render-tmp" "$WORK/live.before"
  cmp "$WORK/live.mp4.knips-render-tmp.pid" "$WORK/pid.before"
done
echo 'PASS failed copy and encoded-render publication clean only their own scratch'

# Exercise the real recovery entry point without launching a recording.
mkdir "$WORK/recovery" "$WORK/units"
cp "$WORK/source.mp4" "$WORK/recovery/orphan.mp4"
printf '%s\n' 'unrelated recovery neighbour' >"$WORK/recovery/orphan.recovering.mp4"
cp "$WORK/recovery/orphan.recovering.mp4" "$WORK/recovering.before"
python3 - "$WORK" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
records = [json.loads(line) for line in (root / 'source.knips.jsonl').read_text().splitlines()]
records[0]['movie'] = 'orphan.mp4'
(root / 'recovery/orphan.knips.jsonl').write_text(''.join(
    json.dumps(record, separators=(',', ':')) + '\n'
    for record in records if record['k'] != 'trailer'))
PY
cat >"$WORK/check_recovery.pas" <<'PAS'
program CheckRecovery;
{$I Knips.inc}
uses
  cmem,
  Knips.ThreadManager,
  SysUtils,
  Knips.ObjC.Runtime,
  Knips.Recording.Recovery;
var
  Pool: Pointer;
  Takes: TRecoveredTakes;
  Count, Swept: Integer;
begin
  IsMultiThread := True;
  Pool := BeginAutoreleasePool;
  try
    Count := RecoverOrphanedTakes(ParamStr(1), Takes, Swept);
    if Count <> 1 then
      raise Exception.CreateFmt('expected one recovered take, got %d', [Count]);
    if not Takes[0].Remuxed then
      raise Exception.Create('recovery did not remux: ' + Takes[0].Note);
    if Takes[0].Bytes <= 0 then
      raise Exception.Create('recovered movie is empty');
    if RecoverOrphanedTakes(ParamStr(1), Takes, Swept) <> 0 then
      raise Exception.Create('completed recovery was repeated');
  finally
    EndAutoreleasePool(Pool);
  end;
end.
PAS
if ! fpc @lwpt.cfg -FU"$WORK/units" -FE"$WORK" -o"$WORK/check_recovery" \
    "$WORK/check_recovery.pas" >"$WORK/compiler.log" 2>&1; then
  cat "$WORK/compiler.log" >&2
  fail 'recovery harness failed to compile'
fi
"$WORK/check_recovery" "$WORK/recovery"
cmp "$WORK/recovery/orphan.recovering.mp4" "$WORK/recovering.before"
rg -q '"recovered":true' "$WORK/recovery/orphan.knips.jsonl"
ffmpeg -nostdin -v error -i "$WORK/recovery/orphan.mp4" -f null -
echo 'PASS orphan recovery remuxes once and preserves the unrelated neighbour'
echo 'file-safety: all synthetic checks passed'
