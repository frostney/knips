# Ports: Windows and Linux

## Executive Summary

- **The neutral core already runs on Linux.** `tools/linux-ci.sh` builds
  a Debian bookworm container with FPC 3.2.2 and the real lwpt 0.7.0
  Linux binary, and runs all sixteen `*.Test.pas` suites plus `lwpt build`
  plus `lwpt format --check` — green on `linux/arm64` and `linux/amd64`.
  The Linux binary is a working `knips` that serves MCP and refuses
  capture with exit 3.
- **The whole program cross-compiles for 64-bit Windows.**
  `tools/win64-cross.sh` bootstraps an FPC 3.2.2 `x86_64-win64` cross
  compiler inside a container and links `knips.exe` plus all sixteen
  suites as PE32+ binaries. Compile-and-link is the gate; nothing about
  Windows *behaviour* is proven.
- **A port is a parallel backend, not an abstraction**
  ([ADR-0005](adr/0005-windows-linux-ports.md)). `TRecordingSession`
  keeps its shape; `{$IFDEF}` picks the implementation; everything
  decidable moves into the neutral, tested units.
- **Windows:** DXGI Desktop Duplication + Media Foundation SinkWriter
  first; Windows.Graphics.Capture later, for window capture.
- **Linux:** XSHM first — a spike already grabs a verified frame off Xvfb
  in CI and writes it as a GIF through the neutral encoder —
  xdg-desktop-portal + PipeWire as the real target; recording writes our
  own APNG/GIF before it writes H.264 through anything `dlopen`ed.
- **No cthreads is a Darwin rule only.** Linux uses `cthreads`; Windows
  uses the RTL's native thread manager.
- Everything a Mac cannot answer is listed under
  [Needs a device](#needs-a-device) and stays unclaimed until it is.

## Where the line already is

Every one of these is compiled and run by `lwpt test` on Linux today, and
none of them branches on the platform — with one deliberate exception,
added in milestone 2: `Knips.App.State`'s `MoviesFolderName` is `Movies`
under `{$IFDEF DARWIN}` and `Videos` elsewhere. That is a *constant
selected by target*, the same shape `Knips.ObjC.TypeEncoding` already
uses for its per-CPU encodings, not a second code path: there is one
`RecordingsDirectory`, one test, and nothing to run twice. It is here
because the host differs, not the code — macOS's home movie folder is
`~/Movies`, the Windows shell's is `Videos` (`FOLDERID_Videos`), and
XDG's default for `XDG_VIDEOS_DIR` is `~/Videos`.

| Unit | What is already portable |
| --- | --- |
| `Knips.Options` | option model, validation, region parsing, bit-rate advice |
| `Knips.App.State` | app state machine, titles, paths, selection maths, window-menu filter, audio-source composition, camera placement |
| `Knips.Recording.LiveMath` | rect clamping, dead zone, easing, which effects a target can have |
| `Knips.Recording.CursorMath` | screen point → frame pixel, sprite clipping, the premultiplied blit |
| `Knips.Recording.Heartbeat` | whether the movie has fallen behind the host clock, and the repeated frame's stamp |
| `Knips.Recording.Sidecar` | the JSON Lines event format: writer, reader, interpolation rule |
| `Knips.Mcp.Params` | MCP tool table, JSON argument mapping, default paths |
| `Knips.Export.ZoomTrack` | post-recording Zoom on Click replayed from the click track |
| `Knips.Export.Cadence` | where a render may synthesise a frame, and what one gap may cost |
| `Knips.Export.SizeEstimate` | the pre-export size range and the in-flight projection |
| `Knips.Export.Bitmap` | BGRA buffer, box/bilinear resampling |
| `Knips.Export.Gif` | histogram, median cut, dithering, LZW |
| `Knips.Export.Apng` | acTL/fcTL/fdAT, PNG filters, paszlib |
| `Knips.Export.Timing` | grid-snapped, drift-free frame delays |
| `Knips.ObjC.TypeEncoding` | Darwin-flavoured, but pure Pascal string work |

`source/knips.pas` also has a non-Darwin branch already: the same
subcommands, the same neutral validation, the same MCP server, and
`ExitUnsupported` (3) for anything that needs a screen. So does
`Knips.Mcp`, whose capture tools refuse in-band off Darwin rather than
disappearing from the tool list.

What is *not* portable is exactly the framework glue: `Knips.Capture.*`,
`Knips.Export.Movie*`, `Knips.Recording`, `Knips.ObjC.Runtime`, and every
`Knips.App.*` unit below the state machine.

## The stance

A port is a **parallel implementation behind the session boundary**, not
an abstraction layered over the macOS code. The reasoning, the
alternatives and the consequences are in
[ADR-0005](adr/0005-windows-linux-ports.md); this section is the
mechanical part.

### What a backend must provide

`knips.pas` and `Knips.Mcp` are both written against `TRecordingSession`
and must stay one implementation, so a backend supplies exactly this and
nothing else:

```pascal
constructor Create(const AOptions: TRecordingOptions);
function StartCapture(out AError: string): Boolean;   // must not block
function FinishCapture(out AError: string): Boolean;  // stop, then finalise
function Run(out AError: string): Boolean;            // CLI: block until stop
function LiveStatistics: TMovieWriterStatistics;      // mid-recording counters
function UpdateSourceRect(const ARect: CGRect): Boolean;
function SupportsLiveUpdate: Boolean;
function LiveUpdateError: string;
property Capturing: Boolean;
property Geometry: TStreamGeometry;
property Report: TRecordingReport;
```

Three notes on that list, because they are where a port goes wrong:

- **`StartCapture` returns immediately.** The menu-bar app needs its own
  event loop to keep turning. On Windows that loop is the message pump;
  on Linux it is the main loop pumping DBus and PipeWire. A backend that
  blocks in `StartCapture` breaks the app but not the CLI, which is the
  worst way to find out.
- **`CGRect` in `UpdateSourceRect` is a leak from macOS** and should
  become a neutral rectangle record in `Knips.Options` before the second
  backend exists. It is the only platform type in the signature.
- **`TRecordingReport` fields a backend cannot fill are zero**, exactly
  as a macOS recording without live effects reports zero live updates.
  No `{$IFDEF}` in the record, no per-platform variants.

### Where new code goes

| Path | Contents |
| --- | --- |
| `source/capture/` | macOS bindings, vendored from lantaarn, untouched ([ADR-0003](adr/0003-vendor-capture-units.md)) |
| `source/capture-windows/` | DXGI/D3D11/Media Foundation/WASAPI bindings |
| `source/capture-linux/` | X11/XSHM, DBus, PipeWire bindings |
| `source/Knips.Recording.pas` | the `{$IFDEF}` that picks a backend |
| `source/Knips.Recording.Windows.pas`, `…Linux.pas` | the backends |

Both new directories go into `[package] units` in `lwpt.toml`. A unit
directory costs nothing on a platform that never `uses` what is in it, and
naming it there is also what puts the units under `lwpt format` — unlike
`source/capture/`, these are ours, not carried, so the formatter owns them.
`source/capture-linux` is already listed for exactly that reason.

`lwpt.cfg` is generated, so its matching `-Fu` line only appears at the
next `lwpt install`; until then the container gate passes
`-Fusource/capture-linux` explicitly on top of `@lwpt.cfg`. When that
`lwpt install` does happen, `lwpt.cfg` gains `-Fusource/capture-linux`
(and `-Fisource/capture-linux`) on macOS too, and that is harmless: a
`-Fu` entry is a *search path*, not a compile list, and no unit reachable
from `source/knips.pas` on Darwin names `Knips.Capture.X11`. The unit is
`{$IFDEF LINUX}`-guarded to an empty shell besides, so even a stray
reference would compile rather than drag in Xlib.

## Windows

### Capture: Desktop Duplication now, Graphics Capture later

**Recommendation: `IDXGIOutputDuplication` for milestone 1.**

| | DXGI Desktop Duplication | Windows.Graphics.Capture |
| --- | --- | --- |
| Reachable from FPC | yes — plain COM vtables, since Windows 8 | only by hand-rolling WinRT activation |
| Per-window capture | no, whole output only | yes |
| Cursor | separate (`PointerPosition` + `GetFramePointerShape`) — we draw it | composited in |
| Border | none | yellow, mandatory on Windows 10 |
| Secure desktop / UAC | `E_ACCESSDENIED`, handle must be recreated | unaffected |
| Hybrid graphics | `DXGI_ERROR_UNSUPPORTED` on the discrete GPU | unaffected |
| Protected content | excluded from the frame | excluded from the frame |

The WinRT cost is the deciding factor. FPC 3.2.2 has no WinRT language
projection, so Windows.Graphics.Capture means: `RoInitialize`,
`RoGetActivationFactory` and `WindowsCreateString` declared against
`combase.dll`; `IInspectable`-derived vtables written out by hand; a
QueryInterface for `IGraphicsCaptureItemInterop` (Windows 10 1903+) to
turn an `HWND` or `HMONITOR` into a `GraphicsCaptureItem` without the
picker UI; and a D3D11 device wrapped through
`CreateDirect3D11DeviceFromDXGIDevice` before
`Direct3D11CaptureFramePool.Create` will take it. On top of that the
yellow capture border cannot be turned off at all on Windows 10, and on
Windows 11 needs a packaged manifest capability plus
`GraphicsCaptureAccess.RequestAccessAsync(Borderless)` and user consent.
That is a spike of its own, justified when *Record Window* is the
milestone — not when "record the screen at all" is.

Desktop Duplication is the opposite trade: it is COM the way Pascal has
always consumed COM (and there are existing Pascal DXGI header
translations to check ours against), it needs a D3D11 device only to
receive the texture, and its limitations are ones Knips can carry —
whole-output capture is what `--display` already means, and a region
recording is a crop we already compute in tested neutral code. The
cursor being separate is genuinely extra work: `AcquireNextFrame` reports
its position each frame, and the shape has to be fetched only when it
changes, then composited by us.

### Encode: Media Foundation SinkWriter

`MFStartup` at process start; `MFCreateSinkWriterFromURL` for the `.mp4`;
`MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS = TRUE` on the creation
attributes to get hardware encoders (it is off by default); one stream
per track (H.264 video, AAC audio) via `AddStream` /
`SetInputMediaType`, then `WriteSample`. The MP4 sink muxes; no
fragmentation flag is needed for an ordinary file. This is the same
bargain as [ADR-0001](adr/0001-avassetwriter-owns-encoding.md): the OS
owns encoding, we own frames and timestamps.

One caveat to surface in the UI rather than crash on: **Windows N/KN
editions ship without the H.264 and AAC MFTs.** They come with the Media
Feature Pack, which the user installs. `knips probe` on Windows should
open and immediately cancel a SinkWriter for exactly this reason, the way
the macOS probe opens and cancels an `AVAssetWriter`.

### App shell

- **Tray icon:** `Shell_NotifyIcon` with `NOTIFYICON_VERSION_4`. Not
  deprecated; the only stale part of `NOTIFYICONDATA` is `uTimeout`,
  which Vista made OS-controlled.
- **Stop hotkey:** `RegisterHotKey`. It registers *per thread*, so the
  registering thread must pump `WM_HOTKEY`; combinations the shell
  reserves cannot be claimed and the call fails, which maps cleanly onto
  the existing `Last error: …` behaviour of the macOS Carbon hotkey.
- **Region overlay:** a layered window (`WS_EX_LAYERED |
  WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW`) per monitor, the direct analogue
  of `KnipsOverlayWindow`. The selection maths is already neutral and
  tested in `Knips.App.State`.
- **Recording border:** the same layered-window trick, click-through.

### Audio

WASAPI. System audio is loopback capture on a render endpoint
(`AUDCLNT_STREAMFLAGS_LOOPBACK`); the microphone is an ordinary capture
endpoint. Per-process audio — the thing SCK gives macOS for free — is a
separate, newer API: `ActivateAudioInterfaceAsync` with
`VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK` and
`AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS`, minimum Windows 10 build 20348.
Out of scope until the basic two work.

## Linux

### Capture: XSHM first, portal + PipeWire as the target

**Recommendation: ship XSHM first, design for PipeWire.**

`xdg-desktop-portal`'s `org.freedesktop.portal.ScreenCast` is the only
future-proof path — under Wayland it is the *only* path — and its flow is
well defined: `CreateSession` → `SelectSources` (source types, cursor
mode, `persist_mode`) → `Start` (the compositor shows its own picker and
returns PipeWire node IDs) → `OpenPipeWireRemote` (returns an fd to
connect a PipeWire context to). Since ScreenCast interface version 4 a
`restore_token` avoids re-prompting on every launch, which is what makes
*Record Last Region* survivable on Linux. Consuming the stream means
`libpipewire-0.3`'s `pw_stream` C API — a stable C ABI, `dlopen`-able, so
the binary still starts where PipeWire is absent. There is **no existing
FreePascal PipeWire binding**; those headers get hand-translated, the way
`source/capture/` was.

The catch is that none of it can be verified from a Mac. A portal needs a
real desktop session with a real compositor; there is no headless
substitute that proves anything.

X11/XSHM is the opposite, and this lane proved it rather than asserting
it. `source/capture-linux/Knips.Capture.X11.pas` is a spike —
`XShmCreateImage` / `XShmAttach` / `XShmGetImage` over a System V shared
segment (FPC's `xshm` unit declares them `external libX11`, though
`libxext-dev` is still needed at link time for the `{$LinkLib Xext}` the
same unit carries) — and `tools/ci/linux-gate.sh` runs it against Xvfb on
every Linux CI run:

```text
display: 1024x768
painted: #3366CC
frame:   320x200, 1280 byte(s) per row, 64000 non-black pixel(s)
checked: 0 pixel(s) differ from the painted colour
gif:     build/x11spike/frame.gif, 406 byte(s), 2 colour(s)
```

The spike paints a known colour into the root through the same X
connection it grabs from, then checks every captured pixel against it —
"not black" would pass a frame with the channels swapped, and
BGRA-versus-RGBA is exactly the mistake a capture path makes. The frame
then goes straight through `TGifQuantizer` and `TGifEncoder`, so the
proof spans the whole width of a Linux recording path in miniature:
X11 → MIT-SHM → `TBgraImage` → a real GIF on disk.

None of that makes it production code: no clock, no damage tracking, no
cursor, no multi-monitor geometry. It is also a dead end — under XWayland
an X11 grab sees only XWayland's own surfaces, not native Wayland windows
— which is precisely why it must never become the only backend. What it
does settle is that a Linux capture path can be built and regression-tested
from a Mac.

So: two backends, one session type, XSHM first because it is testable and
PipeWire second because it is correct.

### Encode: there is no OS encoder

macOS has AVAssetWriter and Windows has Media Foundation. Linux has
nothing comparable, and the options each cost something:

| Option | Cost |
| --- | --- |
| Our own APNG/GIF, direct to disk | no H.264 — but zero dependencies, and the code exists and is tested |
| VA-API (`libva`, `dlopen`) | needs a capable driver and a display connection; absent or broken on plenty of machines |
| `libx264` | **GPL.** Linking it makes Knips GPL. Excluded. |
| `openh264` | BSD source, but Cisco's royalty-covered *binary* only stays royalty-covered if the end user downloads it separately — not if we ship it |
| `libavcodec` (`dlopen`) | LGPL 2.1+ is workable when dynamically linked and replaceable; a `--enable-gpl` build is not |

**Recommendation: our own encoders first.** `Knips.Export.Apng` and
`Knips.Export.Gif` already exist, are neutral, and are tested on Linux
today; a first Linux `knips record --out=demo.apng` needs no new encoder
at all, and GIF was Kap's signature output anyway. `knips record
--out=demo.mp4` refuses with a message rather than pretending. H.264
arrives later as a `dlopen`ed VA-API or LGPL `libavcodec` path — runtime,
optional, never a link-time dependency, matching the project's
dependency-light stance and the flag-free build.

### App shell

- **Tray:** StatusNotifierItem over DBus. Be honest about the state of
  it: SNI is a KDE-driven freedesktop *draft*, native on Plasma, and
  **GNOME Shell does not implement it without a third-party extension**.
  The Linux app shell therefore cannot promise a menu-bar icon
  everywhere, and the CLI stays a first-class way to use Knips on Linux.
- **Stop hotkey:** `org.freedesktop.portal.GlobalShortcuts`
  (xdg-desktop-portal 1.16.0+). The requested chord is only a
  *preferred trigger*; the compositor decides, usually through its own
  configuration dialog. ⌘⇧2's Linux equivalent is therefore a request,
  not a registration, and the failure path already exists in the app's
  `Last error: …` line.
- **Overlay and border:** an override-redirect X11 window under X11; a
  `layer-shell` surface under Wayland, where it exists. Neither is
  needed for a headless `knips record`.

### Audio

PipeWire, through the same `dlopen`ed `libpipewire-0.3` the video stream
uses: a capture stream on the default sink's monitor for system audio, a
capture stream on the default source for the microphone. PulseAudio's
API is reachable the same way if PipeWire is absent, but that is a second
backend inside a backend and is not milestone work.

## Threading

The `cthreads` prohibition is a **Darwin decision**, not a project-wide
one. It exists because ScreenCaptureKit delivers samples on a GCD queue
the RTL never adopts, so `Knips.ThreadManager` installs pthread-backed
locks without ever creating a thread, `cmem` goes first in the
uses-clause, and `IsMultiThread` is set by hand
([docs/architecture.md](architecture.md)).

| Platform | Thread manager | Notes |
| --- | --- | --- |
| macOS | none — `Knips.ThreadManager` + `cmem` + `IsMultiThread := True` | unchanged; the whole no-cthreads discipline stays exactly as documented |
| Linux | `cthreads`, first in the uses-clause | normal FPC; capture and audio threads are ours, so the RTL may as well own them |
| Windows | the RTL's native (Win32) thread manager | no extra unit; threading is built in |

All three live inside the existing `{$IFDEF}` block at the top of
`knips.pas`; `Knips.inc` stays what it is — `{$mode delphi}{$H+}` — and
does **not** grow platform logic. The capture-queue rules (no exceptions,
no `try..finally`, no `WriteLn`, no managed writes outside a mutex) are
worth keeping on every platform anyway: they are what makes a callback
from a foreign thread safe, and they cost nothing.

## Toolchain

`lwpt` stays the only entry point. Two things follow.

**One build entry, not three.** `lwpt build` builds *every* entry in
`[build]` on every platform, which is exactly why `docs/tooling.md`
refuses to commit the `-ld_classic` variant. A `knips-windows` entry
would fail the macOS build for the same reason. `knips.pas` already
selects its platform with `{$IFDEF}`, so the manifest needs no change
beyond the unit directories. **Target state**, not what is committed
today — only `source/capture-linux` exists and is listed;
`source/capture-windows` joins it when there is Windows code to put in it:

```toml
[package]
name = "knips"
units = [
  "source",
  "source/capture",          # macOS, vendored
  "source/capture-windows",  # not yet — added with the Windows backend
  "source/capture-linux",    # added in the foundation lane
  ".lwpt/modules/mcp/source/units",
]

[build]
# Still one entry. Still no flags.
knips = { source = "source/knips.pas", output = "build/knips" }
```

**Cross-target builds go through the container scripts.** lwpt has no
cross-target concept, and `lwpt.cfg` / `lwpt.lock` are generated and must
never be hand-edited. `tools/ci/win64-gate.sh` therefore uses the one
direct-compiler form AGENTS.md sanctions — `fpc @lwpt.cfg` — and adds
only `-Twin64 -Px86_64` and output directories on top of it. Every unit
and include path still comes from the generated `lwpt.cfg`.

### The three scripts

```sh
tools/linux-ci.sh                          # neutral suites + lwpt build + smoke + format
tools/linux-ci.sh --platform linux/amd64   # the same on x86_64
tools/linux-ci.sh -- lwpt test             # any other command in the container

tools/win64-cross.sh                       # compile + link every target for win64
tools/win64-cross.sh -- bash               # poke around inside

tools/wine-smoke.sh                        # the cross-built suites, run under Wine
```

Both mount the checkout **read-only** and copy it inside the container,
so a Linux or Windows build can never leave foreign `.ppu`/`.o` files or
an ELF/PE `build/knips` in a developer's Mac checkout.

Two facts worth knowing before touching `tools/ci/Dockerfile.win64`:

- FPC 3.2.2 predates glibc 2.34, which removed `__libc_csu_init` /
  `__libc_csu_fini`. Bootstrapping a cross compiler rebuilds the *host*
  Linux RTL, whose libc start-up stub still references them, so the first
  host-side link dies. The Dockerfile patches `rtl/linux/*/cprt0.as` to
  pass null instead — what FPC itself did after 3.2.2, and what Debian
  patches into its own package. The greps around the patch make a future
  FPC bump fail loudly rather than silently skip it.
- Debian's `/etc/fpc.cfg` searches a multiarch unit root
  (`/usr/lib/<triplet>/fpc/…`) while `make crossinstall
  INSTALL_PREFIX=/usr` writes upstream's plain `/usr/lib/fpc/…` layout.
  Without three extra `-Fu` lines the win64 RTL is found and nothing else
  is.

## What this Mac can prove

| Claim | Provable here? | How |
| --- | --- | --- |
| Neutral core compiles on Linux | **yes** | `tools/linux-ci.sh`, both architectures |
| Neutral suites pass on Linux | **yes** | all sixteen green in-container |
| `knips` builds and runs on Linux | **yes** | `lwpt build`, `--version`, `record` → exit 3 |
| Formatter agrees on Linux | **yes** | `lwpt format --check` in-container |
| Everything compiles and links for win64 | **yes** | `tools/win64-cross.sh`, PE32+ verified |
| Neutral suites behave Windows-shaped | **partly** | `tools/wine-smoke.sh` — all sixteen green under Wine; Wine is not Windows, but see below |
| XSHM capture grabs a frame | **yes — done** | `source/capture-linux/`, Xvfb, in the gate |
| GIF written from a real Linux capture | **yes — done** | the spike encodes its frame with `Knips.Export.Gif` |
| Anything about Wayland, portals, PipeWire | **no** | needs a real session |
| Anything about DXGI, Media Foundation, WASAPI | **no** | needs a real Windows machine |
| Tray icon behaviour on GNOME/KDE/Windows | **no** | needs a real desktop |

### The one thing Wine already found

*Fixed in milestone 2; kept here because what it found is the argument
for keeping the smoke. As of that milestone every suite is green
under Wine, 0 failing tests.*

`tools/wine-smoke.sh` runs the cross-built suites under Wine 8.0 in an
amd64 container. On its first run eight of 323 tests failed, all of them
in one file: `source/Knips.Mcp.Params.Test.pas`. **None of the eight was
a bug in the production neutral core** — every one was a defect in the
test file, and tracing them is what turned up the single real
portability item.

```text
default paths › a recording defaults into ~/Movies/knips/
  Expected "/Users/tester\Movies\knips\knips-….mp4"
        to be "/Users/tester/Movies/knips/knips-….mp4"
BuildMcpRecordingOptions › no arguments record … to the default path
  Expected "Z:\tmp\default.mp4" to be "/tmp/default.mp4"
BuildMcpRecordingOptions › the output path comes back absolute
  Expected False to be True
```

Read the first two the right way round: the *actual* value is the correct
one. `RecordingsDirectory` already builds its path with
`IncludeTrailingPathDelimiter` and `PathDelim`
(`Knips.App.State.pas`), so it produced `\` on Windows exactly as it
should; `ExpandFileName` correctly resolved `/tmp/default.mp4` to Wine's
`Z:\tmp\default.mp4`. What failed is the *expected* side — six stale
POSIX literals baked into the fixtures.

The third is a bad predicate rather than a stale literal:
`Recording.OutputPath[1] = PathDelim`, twice in
`Knips.Mcp.Params.Test.pas`, asks whether the first character is a
separator. On Windows an absolute path starts with a drive letter, so that
check fails by construction —
and no production code performs it. `Knips.Mcp.Params` calls
`ExpandFileName` and trusts the RTL, which is right.

So the tally was **six stale test literals plus two wrong test
predicates**, and one genuine production item that only surfaced because
the suite was run: `MoviesFolderName = 'Movies'`
(`Knips.App.State.pas`). A Windows recording belongs in `Videos`, and
so does a Linux one — that is a product decision, not a separator bug,
and it was the only line of shipped code the Wine run indicted. (One
kindred line escaped only because no test asserts tool-description
prose: `record_start`'s schema text in `Knips.Mcp.pas` still says
`~/Movies/knips/` — deferred to the milestone that makes the MCP
surface platform-honest as a whole.)

**How they were fixed.** The six literals became expectations built the
way the production code builds the value: `PathDelim` and
`MoviesFolderName` for the default recording path, and
`ExpandFileName('/tmp/…')` wherever a builder returns an expanded path,
because *which* path was chosen is the claim and the expansion is
incidental to it. Several of them gained a structural assertion beside
the string — a GIF default now also asserts that it shares its input's
directory and stem, which is what "beside its input" actually means and
what a literal only implied. The two predicates became one local
`IsRootedPath` helper in the test file, accepting a leading `/`, a
`\\server\share` UNC, and an `X:\` or `X:/` drive root; FPC 3.2.2 has no
portable predicate for this, no production code needs one, and the helper
has its own test so the two assertions that lean on it cannot go vacuous.

One toolchain hazard found on the way, worth knowing before editing any
suite: **a comment inside a `uses` clause makes `lwpt format` rewrite the
file into garbage** rather than refusing it. `lwpt format --check` only
reports "needs formatting", so the damage appears at the rewrite. Keep
unit-list commentary in the header comment above `uses`.

That is a smaller finding than it first looked, and worth stating plainly:
the neutral core's path handling was already portable. What the Wine smoke
actually earns is the *test suite's* portability — a compiler that happily
linked a Windows executable for every suite had nothing to say about any of
it, which is the argument for keeping the smoke around even though Wine is
not Windows.

### Needs a device

The same ledger `docs/spikes/0001-runtime-objc-class.md` keeps for macOS,
for the ports. Nothing here may be described as working until it is
checked off.

**Windows (needs a real Windows 10/11 machine):**

1. `IDXGIOutput1::DuplicateOutput` succeeds and delivers frames from
   Pascal-declared vtables — and the `E_ACCESSDENIED` / recreate path on
   a UAC prompt is handled, not fatal.
2. Cursor shape composition matches what a user expects (position,
   hotspot, masked vs colour cursors).
3. `MFCreateSinkWriterFromURL` produces a file Windows Media Player and
   QuickTime both open, with hardware transforms enabled and disabled.
4. Behaviour on a Windows N edition without the Media Feature Pack is a
   message, not a crash.
5. `RegisterHotKey` actually delivers `WM_HOTKEY` for the chosen chord
   (the same "the system reports success for a chord it will not
   deliver" trap the macOS hotkey has).
6. Hybrid-graphics laptops: which adapter the duplication runs on.

**Linux (needs a real desktop session):**

1. The portal dialog appears, `Start` returns a node ID, and
   `OpenPipeWireRemote` yields a usable fd — on GNOME *and* KDE, which
   have different backends.
2. `restore_token` genuinely suppresses the second prompt.
3. `pw_stream` format negotiation gives us something we can turn into
   BGRA without a copy per frame.
4. StatusNotifierItem shows up on Plasma, and what a GNOME user actually
   sees without the extension.
5. `GlobalShortcuts` binding survives a session restart.
6. XSHM under XWayland: confirm it captures nothing useful, so the
   fallback disables itself instead of recording a black rectangle.

## Milestones

1. **Foundation — this lane.** Linux CI container and gate; win64
   cross-compile gate; the Wine smoke; the X11/MIT-SHM capture spike; this
   document and [ADR-0005](adr/0005-windows-linux-ports.md). No backend
   code beyond the spike, and the spike is not a backend.
2. **Make the neutral suite portable, and settle Movies-vs-Videos.
   Done.** In `Knips.Mcp.Params.Test.pas` the six stale POSIX literals
   became expectations built the way the production code builds the
   value — `PathDelim` and `MoviesFolderName` for the default recording
   path, `ExpandFileName` of the same literal wherever a builder returns
   an expanded path — with structural assertions (same directory, same
   stem) added where a literal had only implied the claim; and the two
   `OutputPath[1] = PathDelim` predicates became a local `IsRootedPath`
   helper that accepts both families' roots and carries its own test.
   `MoviesFolderName` (`Knips.App.State.pas`) is now `Movies` under
   `{$IFDEF DARWIN}` and `Videos` elsewhere — the unit's one conditional,
   a constant selected by target rather than a second code path. The path
   helpers themselves already used `PathDelim` and needed no change.
   Verified: every suite green under `tools/wine-smoke.sh` (0 failing
   tests, was 8), `tools/linux-ci.sh` green on arm64, and `lwpt build` /
   `lwpt test` / `lwpt format --check` green on macOS.
3. **Linux headless recorder.** `source/capture-linux/` XSHM bindings,
   `Knips.Recording.Linux`, `knips record --out=demo.apng` and
   `demo.gif` working against Xvfb in CI, `knips probe` growing a Linux
   arm. Neutral rectangle type replaces `CGRect` in the session
   signature. This is the first milestone that produces a file on a
   second platform, and all of it is verifiable from a Mac.
4. **Linux desktop.** Portal + PipeWire backend behind the same session;
   `restore_token`; StatusNotifierItem tray; GlobalShortcuts stop
   hotkey; overlay. Needs a device from here on.
5. **Windows capture spike.** Desktop Duplication + SinkWriter to a
   file, headless `knips record` only, on real hardware — the Windows
   equivalent of spike 0001, with its own spike document and its own
   `knips probe` arm.
6. **Windows app.** Tray, overlay, hotkey, WASAPI audio.
7. **Parity.** Window capture (Windows.Graphics.Capture on Windows,
   portal window sources on Linux), live effects, camera, playback and
   the export window.

## Related documents

- [ADR-0005: Windows and Linux as parallel backends](adr/0005-windows-linux-ports.md)
- [ADR-0004: platform-neutral core, testable off-device](adr/0004-neutral-core-testable-off-device.md)
- [ADR-0003: vendored capture units](adr/0003-vendor-capture-units.md)
- [ADR-0001: AVAssetWriter owns encoding](adr/0001-avassetwriter-owns-encoding.md)
- [Architecture](architecture.md) — threading model, session shape
- [Tooling](tooling.md) — lwpt, pins, the off-device type-check
- [VISION.md](../VISION.md) — "not cross-platform in this release"

## Grounding

Platform facts here were checked against current vendor documentation
(August 2026), not recalled — the same rule AGENTS.md applies to
framework bindings:

- `IGraphicsCaptureItemInterop::CreateForWindow` / `CreateForMonitor`,
  Windows 10 1903+ —
  https://learn.microsoft.com/en-us/windows/win32/api/windows.graphics.capture.interop/nn-windows-graphics-capture-interop-igraphicscaptureiteminterop
- WinRT activation from a language without a projection (`RoInitialize`,
  `RoGetActivationFactory`, `combase.dll`) —
  https://learn.microsoft.com/en-us/windows/win32/api/roapi
- `GraphicsCaptureSession.IsBorderRequired` and the borderless capability —
  https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.isborderrequired
- Desktop Duplication on hybrid graphics (`DXGI_ERROR_UNSUPPORTED`) —
  https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/error-when-dda-capable-app-is-against-gpu
- `IDXGIOutputDuplication::GetFramePointerShape` (cursor is separate) —
  https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgioutputduplication-getframepointershape
- `MFCreateSinkWriterFromURL` —
  https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-mfcreatesinkwriterfromurl
- `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS` —
  https://learn.microsoft.com/en-us/windows/win32/medfound/mf-readwrite-enable-hardware-transforms
- Media Feature Pack for Windows N editions —
  https://support.microsoft.com/en-us/windows/experience/platform-variants/media-feature-pack-for-windows-10-11-n-february-2023
- Per-process loopback (`AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS`) —
  https://learn.microsoft.com/en-us/windows/win32/api/audioclientactivationparams/ns-audioclientactivationparams-audioclient_process_loopback_params
- `Shell_NotifyIcon` (`uTimeout` deprecated since Vista) —
  https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shell_notifyiconw
- ScreenCast portal flow and `restore_token` (interface version 4) —
  https://github.com/flatpak/xdg-desktop-portal/blob/main/data/org.freedesktop.portal.ScreenCast.xml
- `pw_stream` C API —
  https://docs.pipewire.org/group__pw__stream.html
- XSHM (`XShmGetImage`; the MIT-SHM extension, declared by FPC's `xshm`
  unit as `external libX11`) —
  https://manpages.debian.org/bullseye/libxext-dev/XShmGetImage.3.en.html
- XWayland capture limits —
  https://blog.davidedmundson.co.uk/blog/xwaylandvideobridge/
- x264 licensing (GPL, or a commercial licence) —
  https://x264.org/licensing/
- OpenH264 binary licence —
  https://www.openh264.org/BINARY_LICENSE.txt
- FFmpeg licensing (LGPL by default, GPL with `--enable-gpl`) —
  https://www.ffmpeg.org/legal.html
- GlobalShortcuts portal, xdg-desktop-portal 1.16.0 —
  https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html
- StatusNotifierItem needs an extension on GNOME Shell —
  https://extensions.gnome.org/extension/615/appindicator-support/
