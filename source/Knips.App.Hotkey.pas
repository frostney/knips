unit Knips.App.Hotkey;

// The system-wide stop hotkey: ⌘⇧2 stops a running recording from
// wherever the user is, without going back to the menu bar. Kap has the
// same gesture and it is the one thing a recorder is asked for that a
// status item cannot do — while Knips records, the status item has no
// menu at all (a single click stops it), and the window the user is
// demonstrating in is the one thing they should not have to leave.
//
// **Carbon, deliberately.** RegisterEventHotKey is the one route to a
// global hotkey that needs no TCC grant: it is the same mechanism the
// system's own keyboard shortcuts use, the window server matches the
// chord and posts an event to the registering process, and no key the
// user presses anywhere else is ever seen by this app. The alternatives
// all cost a permission this recorder has no business asking for —
// NSEvent's addGlobalMonitorForEventsMatchingMask: and a CGEventTap both
// need Input Monitoring, which is a "Knips wants to read everything you
// type" dialog in exchange for one chord.
//
// Header-verified against FPC 3.2.2's univint (MacOSAll re-exports
// CarbonEvents and CarbonEventsCore), and read back at run time by
// `knips probe`:
//
//   RegisterEventHotKey(code, modifiers, id, target, options, out ref)
//   UnregisterEventHotKey(ref)
//   InstallEventHandler(target, upp, count, specs, userData, out ref)
//   RemoveEventHandler(ref)
//   GetApplicationEventTarget
//   kVK_ANSI_2 = 19, cmdKey = 256, shiftKey = 512
//   kEventClassKeyboard / kEventHotKeyPressed
//
// One measured surprise, and it is why registration success is not
// treated as proof of anything: **RegisterEventHotKey answers noErr for a
// chord the system already owns.** Registering ⌘⇧3 — the screenshot
// shortcut — returns 0 just as ⌘⇧2 does; what the system keeps is the
// *delivery*, not the registration. A second registration of the same
// chord by the same process is the case that is caught, with
// eventHotKeyExistsErr (-9878). So a failure here is reported as a Last
// error, and a chord that registers but never fires is a thing only a
// human pressing the keys can find out (docs/quick-start.md says so).
//
// NewEventHandlerUPP is deliberately not used: on every architecture this
// project targets a UPP *is* the function pointer (the CFM thunk is long
// gone), the symbol is not in the framework at all — linking against it
// fails outright, measured — and Apple's own header defines the call as
// the identity. The cdecl handler is cast straight to EventHandlerUPP.
//
// **Threading.** The handler runs on the main thread's run loop:
// NSApplication.run drives the Carbon event dispatcher, which is what
// hands a hotkey event to the application event target. So the body is
// ordinary main-thread code and may talk to the controller — but it is a
// foreign frame like every other callback in this app (AppKit's menu
// actions, the border's drawRect:, the camera's mouseDown:), so it is
// wrapped in try..except and lets nothing back into C.
//
// **What the hotkey does is exactly one thing: stop.** It is not a
// toggle. A global chord that could *start* a recording is a global
// chord that starts one by accident, and the app's own state machine
// only accepts acStopRecording in asRecording anyway — outside that
// state the handler runs, finds nothing to stop, and returns. The stop
// itself goes through the same CommandStop the status-item click does,
// deferred by the same stopPending: one-shot, so there is one stop path
// and not two.

{$I Knips.inc}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$ENDIF}

interface

{$IFDEF DARWIN}

uses
  SysUtils,

  Knips.App.State,
  MacOSAll;

// HIToolbox, where the Carbon Event Manager lives. A source directive, not
// a build flag: the default `knips` build entry stays linker-flag-free
// (AGENTS.md), exactly as Knips.App.Camera links AVFoundation.
{$linkframework Carbon}

type
  TStopHotKeyEvent = procedure of object;
  TStopHotKeyErrorEvent = procedure(const AMessage: string) of object;

  // One per process. Carbon has no ivar to hang an owner off, so the
  // cdecl handler finds its object through a unit-level pointer that
  // Install sets and Remove clears; a second instance is refused rather
  // than allowed to overwrite it.
  TStopHotKey = class
  private
    FHotKey: EventHotKeyRef;
    FHandler: EventHandlerRef;
    FInstalled: Boolean;
    FOnPressed: TStopHotKeyEvent;
    FOnError: TStopHotKeyErrorEvent;
  public
    destructor Destroy; override;
    // Installs the application-target event handler and registers the
    // chord. False with a message when either half fails; the app then
    // runs without the hotkey rather than refusing to start — the status
    // item still stops a recording with one click.
    function Install(out AError: string): Boolean;
    // Idempotent, and safe on a half-installed object: Quit calls it, and
    // so does the destructor.
    procedure Remove;
    // Called by the cdecl handler. Public only for that.
    procedure Fire;
    property Installed: Boolean read FInstalled;
    property OnPressed: TStopHotKeyEvent read FOnPressed write FOnPressed;
    property OnError: TStopHotKeyErrorEvent read FOnError write FOnError;
  end;

// `knips probe`'s gate: registers the chord, reads the constants back out
// of the framework headers, unregisters, and reports one line. ADetail is
// what the probe prints. False with a reason when the round trip did not
// take — which is the failure worth catching, since every one of these
// calls answers an OSStatus that is easy to ignore.
function CheckStopHotKey(out ADetail: string; out AError: string): Boolean;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  // 'knps', so an event that somehow reaches the handler from anything
  // else is ignored rather than mistaken for ours.
  HotKeySignature = $6B6E7073;
  HotKeyID = 1;
  // Carbon's "no options"; spelled out because kEventHotKeyNoOptions is
  // the kind of constant that is easier to read than to look up.
  HotKeyNoOptions = 0;
  // eventHotKeyExistsErr, the one registration failure that means
  // something actionable: this process already holds the chord.
  HotKeyExistsErr = -9878;

var
  // The one instance, or nil. See the class comment: Carbon gives the
  // handler a void* userData, which would do — but it is handed back
  // untyped from a frame this unit cannot audit, and a module pointer
  // this unit sets and clears itself is the same discipline every other
  // callback in the app uses for its owner ivar.
  GHotKey: TStopHotKey = nil;

// The Carbon event handler. Runs on the main thread inside NSApp's run
// loop (see the unit header) and must never let a Pascal exception back
// into C, exactly like every AppKit body in Knips.App.
//
// noErr either way: the event was ours and has been handled. Answering
// eventNotHandledErr would send it on down the handler chain, which for a
// hotkey nothing else registered means nowhere.
function StopHotKeyHandler(ACall: EventHandlerCallRef; AEvent: EventRef;
  AUserData: Pointer): OSStatus; cdecl;
var
  Fired: EventHotKeyID;
  Owner: TStopHotKey;
begin
  Result := OSStatus(noErr);
  Owner := nil;
  try
    Owner := GHotKey;
    if Owner = nil then
      Exit;
    // Which hotkey. Only one is ever registered, so this is belt and
    // braces — but the handler sits on the *application* target and
    // would see any other hotkey this process ever grows, and firing a
    // stop for somebody else's chord is the kind of bug that only shows
    // up once there is a second one.
    Fired.signature := 0;
    Fired.id := 0;
    if GetEventParameter(AEvent, kEventParamDirectObject, typeEventHotKeyID,
      nil, SizeOf(Fired), nil, @Fired) <> OSStatus(noErr) then
      Exit;
    if (Fired.signature <> HotKeySignature) or (Fired.id <> HotKeyID) then
      Exit;
    Owner.Fire;
  except
    on E: Exception do
      try
        if (Owner <> nil) and Assigned(Owner.FOnError) then
          Owner.FOnError('the ' + StopHotKeyDisplay + ' hotkey: ' + E.Message);
      except
        // Nothing left to try; swallowing beats unwinding into Carbon.
      end;
  end;
end;

{ TStopHotKey }

destructor TStopHotKey.Destroy;
begin
  Remove;
  inherited Destroy;
end;

function TStopHotKey.Install(out AError: string): Boolean;
var
  Spec: EventTypeSpec;
  Identifier: EventHotKeyID;
  Status: OSStatus;
begin
  Result := False;
  AError := '';
  if FInstalled then
    Exit(True);
  if GHotKey <> nil then
  begin
    AError := 'a global hotkey is already installed in this process';
    Exit;
  end;

  // The module pointer goes in *before* the handler, or an event
  // delivered between the two would find no owner. Cleared on every
  // failure path below, so a refused install leaves nothing behind.
  GHotKey := Self;

  Spec.eventClass := kEventClassKeyboard;
  Spec.eventKind := kEventHotKeyPressed;
  FHandler := nil;
  Status := InstallEventHandler(GetApplicationEventTarget,
    EventHandlerUPP(@StopHotKeyHandler), 1, @Spec, nil, @FHandler);
  if Status <> OSStatus(noErr) then
  begin
    GHotKey := nil;
    FHandler := nil;
    AError := Format('the %s hotkey could not be installed: '
      + 'InstallEventHandler returned %d', [StopHotKeyDisplay, Status]);
    Exit;
  end;

  Identifier.signature := HotKeySignature;
  Identifier.id := HotKeyID;
  FHotKey := nil;
  Status := RegisterEventHotKey(StopHotKeyVirtualCode,
    StopHotKeyCarbonModifiers, Identifier, GetApplicationEventTarget,
    HotKeyNoOptions, FHotKey);
  if (Status <> OSStatus(noErr)) or (FHotKey = nil) then
  begin
    FHotKey := nil;
    if FHandler <> nil then
    begin
      RemoveEventHandler(FHandler);
      FHandler := nil;
    end;
    GHotKey := nil;
    if Status = HotKeyExistsErr then
      AError := Format('the %s hotkey is already registered by this process',
        [StopHotKeyDisplay])
    else
      AError := Format('the %s hotkey could not be registered: '
        + 'RegisterEventHotKey returned %d', [StopHotKeyDisplay, Status]);
    Exit;
  end;

  FInstalled := True;
  Result := True;
end;

procedure TStopHotKey.Remove;
begin
  // The chord first: an event already in flight would then find the
  // handler still installed and the owner still there, where the reverse
  // order leaves a live chord with nothing to dispatch it.
  if FHotKey <> nil then
  begin
    UnregisterEventHotKey(FHotKey);
    FHotKey := nil;
  end;
  if FHandler <> nil then
  begin
    RemoveEventHandler(FHandler);
    FHandler := nil;
  end;
  if GHotKey = Self then
    GHotKey := nil;
  FInstalled := False;
end;

procedure TStopHotKey.Fire;
begin
  if Assigned(FOnPressed) then
    FOnPressed;
end;

function CheckStopHotKey(out ADetail: string; out AError: string): Boolean;
var
  HotKey: TStopHotKey;
begin
  Result := False;
  ADetail := '';
  AError := '';
  HotKey := TStopHotKey.Create;
  try
    if not HotKey.Install(AError) then
      Exit;
    // Read back rather than assumed: the constants are the half of this
    // that a toolchain change could quietly move, and a hotkey registered
    // on the wrong key code would look exactly like a hotkey that does
    // not work.
    ADetail := Format('%s registered and released (virtual key %d, '
      + 'modifiers %d = cmdKey %d + shiftKey %d)', [StopHotKeyDisplay,
      StopHotKeyVirtualCode, StopHotKeyCarbonModifiers, cmdKey, shiftKey]);
    if (StopHotKeyVirtualCode <> kVK_ANSI_2)
      or (StopHotKeyCarbonModifiers <> (cmdKey or shiftKey)) then
    begin
      AError := Format('the hotkey constants no longer match the headers: '
        + 'kVK_ANSI_2 is %d and cmdKey or shiftKey is %d',
        [kVK_ANSI_2, cmdKey or shiftKey]);
      Exit;
    end;
    Result := True;
  finally
    // Always: the probe must not leave the chord held by a process that
    // is about to exit, and must not leave GHotKey pointing at a freed
    // object if it does not.
    HotKey.Free;
  end;
end;

{$ENDIF}

end.
