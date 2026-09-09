# Computer Use timeout diagnosis — 2026-09-09

## Finding

The installed Computer Use service reproducibly times out when inspecting an
accessory app with no visible window. Opening an ordinary window in the same
app makes inspection succeed. Closing that window reproduces the failure
while the same process remains alive. This isolates a Computer Use interaction
boundary; it does not identify the internal service function that times out.

Knips starts as an accessory app with a status item and no ordinary window
(`RunMenuBarApp` in `source/Knips.App.pas`). The original Knips failure remains
unfixed. Changing Knips's normal startup UI solely for this tool is not a
supported product fix.

## Observed differential test

All UI operations used `node_repl` and the installed `@oai/sky` API. Each call
had a 30-second outer execution budget. The service itself returned
`Computer Use server error -10005: timeoutReached` in roughly five seconds.

| Target/state | Result | Elapsed |
| --- | --- | --- |
| Audit Knips, full bundle path, repeated baseline | Timeout | 5.050–5.074 s |
| Installed Knips, full bundle path | Timeout | 5.048 s |
| Unique minimal accessory app, status item only | Timeout | 5.413 s |
| Same minimal app, ordinary window visible | UI tree and screenshot returned | 0.971 s |
| Repeat with 60-second process lifetime, window visible | UI tree returned | 0.993 s |
| Same PID 5718 after clicking its window's close button | Timeout; PID still alive | 5.105 s |
| Original audit Knips, final recheck | Timeout | 5.051 s |
| Finder, final control | UI tree returned | 3.959 s |

The minimal app has the unique identity `org.knips.cu-diagnosis` and uses
AppKit plus the repository's allocator/thread/runtime setup. It contains no
Knips controller, capture, selection, or recording code. Accessory activation
policy stays unchanged between the successful and failing states. Thus neither
that policy alone nor the duplicate Knips bundle identifier explains the
failure. No permission changes were needed for the successful window test.

A sample of the audit Knips process showed its main thread waiting normally
in the AppKit event loop. Sampling the compiled Computer Use service and
targeted unified-log queries did not expose a useful internal timeout stage.
Its implementation source was not available, so an internal service repair or
regression test cannot be made in this repository.

## Reproducer

Source: [computer-use-window-probe.pas](repro/computer-use-window-probe.pas).
The app exits automatically after 60 seconds. The generated local bundle and
units are confined to ignored `build/cu-diagnosis/`.

From the worktree root, prepare the bundle:

```sh
mkdir -p 'build/cu-diagnosis/Knips CU Probe.app/Contents/MacOS' \
  'build/cu-diagnosis/Knips CU Probe.app/Contents/Resources' \
  build/cu-diagnosis/units
python3 - <<'PY'
import plistlib
from pathlib import Path
bundle = Path('build/cu-diagnosis/Knips CU Probe.app')
with (bundle / 'Contents/Info.plist').open('wb') as stream:
    plistlib.dump(dict(CFBundleIdentifier='org.knips.cu-diagnosis',
                      CFBundleName='Knips CU Probe', CFBundleExecutable='probe',
                      CFBundlePackageType='APPL', LSUIElement=True), stream)
(bundle / 'Contents/Resources/show-window').touch()
PY
fpc @lwpt.cfg -FUbuild/cu-diagnosis/units \
  '-obuild/cu-diagnosis/Knips CU Probe.app/Contents/MacOS/probe' \
  docs/audits/repro/computer-use-window-probe.pas
codesign --force --deep --sign - 'build/cu-diagnosis/Knips CU Probe.app'
```

In the supported Computer Use Node REPL, set `app` to that bundle's absolute
path. This inspects the actual service seam, asserts a visible window, closes
it through its fresh accessibility control, then records the failure:

```js
var sky = (await import('@oai/sky')).sky;
var state = await sky.get_app_state({app, disableDiff: true});
if (!state.text.includes('Knips Computer Use diagnostic window'))
  throw new Error('Diagnostic window was not found');
nodeRepl.write(state.text);
// Inspect the returned tree for the current close-button index.
// It was 1 in the observed runs; use the freshly returned index.
```

Then call `sky.click({app, element_index: closeIndex})` and immediately:

```js
var start = Date.now();
try {
  var result = await sky.get_app_state({app});
  nodeRepl.write(JSON.stringify({verdict:'PASS', ms:Date.now()-start,
                                text:result.text}));
} catch (error) {
  nodeRepl.write(JSON.stringify({verdict:'FAIL', ms:Date.now()-start,
                                error:String(error)}));
}
```

Use `pgrep -fl 'cu-diagnosis/.*/probe'` before closing the window and after the
failing call to distinguish a windowless living process from the 60-second
automatic exit. For a cold menu-only test, omit the `show-window` file before
signing and launch after the previous instance has exited.

## Consequences for the requested checks

Computer Use works for ordinary app windows in this session. The exposed API
cannot currently inspect the idle Knips status item, so it cannot reach Record
Region from that state. The follow-up below verified a working route: a
temporary build opens the existing Record Region action at startup, after
which Computer Use can inspect and operate the actual borderless overlay.

The shell-launched ScreenCaptureKit probe's TCC denial is a separate observed
problem; this reproducer never invokes ScreenCaptureKit. Terminal UI is also
explicitly blocked by the tool. OpenAI documents that restriction and desktop
testing support in its [Computer Use documentation](https://learn.chatgpt.com/docs/computer-use).

No production source changes or OS permission changes were made for this
diagnosis. The follow-up below establishes a working test-build route.

## Follow-up: a test build unlocks real UI checks

Direct `press_key` against idle Knips was also refused: Computer Use requires
a successful `get_app_state` before allowing actions. Finder's accessibility
tree exposed its application menu, but not Knips's status item.

A copy of the audit source in ignored `build/cu-ui-check/source/` was compiled
with `fpc @lwpt.cfg -O4`, using separate units and a separate application
bundle. The only diagnostic changes to `Knips.App.pas` were:

1. Schedule the existing `recordRegion:` action immediately after setup.
2. For capture tests, schedule the existing `stopRecording:` action five
   seconds after capture starts.
3. Put diagnostic recordings in `build/cu-ui-check/recordings/`.

The bundle retained Knips's normal development signing identity. No TCC
settings were changed. The exact temporary source diff is preserved in
`build/cu-ui-check/startup-and-stop.patch`; production source was unchanged.

This succeeded: Computer Use inspected the actual borderless overlay and
delivered keyboard and mouse input. Its screenshot initially showed the
inactive display's overlay; Tab made the selected region visible there.

| Check | Observed result |
| --- | --- |
| Tab / Shift+Tab | Selection switched between the two displays |
| Shift+Right | Selection width changed from 1720 to 1730 points; height stayed 720 |
| Option+Shift+Right | Width changed from 1730 to 1731 points |
| Right | Selection moved right without changing its dimensions |
| Escape | Overlay dismissed, returning to the known windowless-state timeout |
| Return | Real capture started; a recording border appeared |
| Mouse drag | A second real capture started and produced a 750 × 468 take |
| Knips playback | Play control changed to on; timeline advanced to the end at 5.355 seconds |
| Publication | Both takes produced raw/rendered MP4s and corresponding sidecars, with no pending recording files or PID markers left |

The first take (`knips-20260909-181133`) contains 133 raw video frames at
1720 × 720; its trailer records 5.325 seconds. The rendered file contains 140
frames and lasts 5.355 seconds. The second take (`knips-20260909-181346`)
contains 138 raw / 143 rendered frames at 750 × 468. All four movies decode
without errors using FFmpeg with `-fps_mode passthrough -enc_time_base demux`.
The first pair's video packet PTS and DTS are strictly increasing. FFmpeg's
default null-output time base produced rounding warnings for the rendered
file; preserving the demuxer time base removed them.

Follow Mouse was enabled by the existing preferences. The first take contains
37 framing samples: source X varied from 193.761 to 789.919 and source Y from
0.002 to 251.699 while width/height stayed 1720 × 720. This verifies live
framing changed during a real capture after the live-zoom cleanup; it does
not establish docked-camera coordination. System audio samples were silent,
and the app reported that condition in the playback title and log.

Screenshots and recordings remain local under ignored `build/cu-ui-check/`.
The temporary Knips app was quit after testing. The test route does not
verify opening the status menu, the global stop shortcut, keypad Enter,
docked-camera movement, overwriting an existing real take, or killed-capture
recovery. QuickTime verification remains pending: its windowless startup also
timed out, and attempted Finder navigation encountered concurrent UI changes.
