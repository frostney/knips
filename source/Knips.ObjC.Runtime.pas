unit Knips.ObjC.Runtime;

// Objective-C classes built at run time through libobjc's C API instead
// of FPC's `objcclass` syntax. This is the spike ADR-0002 rests on: an
// FPC-defined objcclass makes the compiler emit method-list metadata that
// the current Apple linker (ld-prime) rejects unless the whole build
// carries -ld_classic. A class assembled with objc_allocateClassPair /
// class_addMethod / objc_registerClassPair has no such metadata — every
// method is a plain cdecl Pascal routine the runtime is handed a pointer
// to — so the default build stays linker-flag-free.
//
// The runtime bindings come from FPC's own `objc` unit (rtl/inc/objc.pp),
// verified against the 3.2.2 sources; nothing is hand-declared here except
// the fixed-signature objc_msgSend aliases.

{$I Shared.inc}

interface

{$IFDEF DARWIN}

uses
  ctypes,
  SysUtils,

  objc;

type
  // A method body: a `cdecl` routine whose first two parameters are the
  // receiver (id) and the selector (SEL), followed by the declared ones.
  TObjCMethodImplementation = Pointer;

  EObjCRuntime = class(Exception);

  // Assembles one class. Ivars and methods must be added before Register;
  // the runtime rejects both once the class pair is registered.
  TRuntimeClassBuilder = class
  private
    FName: string;
    FClass: pobjc_class;
    FRegistered: Boolean;
    procedure EnsureOpen;
  public
    constructor Create(const AName, ASuperclassName: string);
    function AddPointerIvar(const AName: string): Boolean;
    function AddMethod(const ASelector: string;
      AImplementation: TObjCMethodImplementation;
      const ATypeEncoding: string): Boolean;
    // False when the runtime has no protocol of that name registered.
    // Protocols only exist at run time when some loaded image references
    // them, so callers treat a miss as a warning, not an error.
    function AddProtocol(const AName: string): Boolean;
    function Register: pobjc_class;
    property Name: string read FName;
    property Handle: pobjc_class read FClass;
    property Registered: Boolean read FRegistered;
  end;

function LookUpClass(const AName: string): pobjc_class;
// A registered selector for the given name. Callers pass these to
// framework methods that take a SEL (menu item actions, timer targets).
function SelectorNamed(const AName: string): SEL;
// alloc + init on the given class; nil when either fails.
function InstantiateClass(AClass: pobjc_class): id;
// alloc only, for classes whose superclass has a designated initialiser
// other than -init (NSView's initWithFrame:, NSWindow's
// initWithContentRect:...). Send that initialiser through the framework's
// own external binding after casting the result.
function AllocateInstance(AClass: pobjc_class): id;
procedure ReleaseInstance(AInstance: id);
procedure SetPointerIvar(AInstance: id; const AIvarName: string;
  AValue: Pointer);
function GetPointerIvar(AInstance: id; const AIvarName: string): Pointer;
function RespondsToSelector(AInstance: id; const ASelector: string): Boolean;
// Whether the class (or an ancestor) has an implementation for the
// selector, without needing an instance. `knips probe` uses it on the
// overlay classes, whose instances would need a window to be worth making.
function ClassImplementsSelector(AClass: pobjc_class;
  const ASelector: string): Boolean;

{$ENDIF}

implementation

{$IFDEF DARWIN}

const
  PointerIvarTypeEncoding = '^v';
  // log2(alignment) as class_addIvar wants it: 3 → 8 bytes on 64-bit.
  PointerIvarAlignmentLog2 = 3;

// Fixed-signature aliases of objc_msgSend. On arm64 every message send
// goes through the same entry point; the C prototype just has to match
// the selector's real signature, which these do.
function MessageSendId(ASelf: id; AOperation: SEL): id;
  cdecl; external name 'objc_msgSend';
procedure MessageSendVoid(ASelf: id; AOperation: SEL);
  cdecl; external name 'objc_msgSend';
function MessageSendBoolSel(ASelf: id; AOperation: SEL;
  AArgument: SEL): ObjCBOOL; cdecl; external name 'objc_msgSend';

function Selector(const AName: string): SEL; inline;
begin
  Result := sel_registerName(PAnsiChar(AName));
end;

{ TRuntimeClassBuilder }

constructor TRuntimeClassBuilder.Create(const AName, ASuperclassName: string);
var
  Superclass: pobjc_class;
begin
  inherited Create;
  FName := AName;
  Superclass := LookUpClass(ASuperclassName);
  if Superclass = nil then
    raise EObjCRuntime.CreateFmt('superclass %s is not loaded',
      [ASuperclassName]);
  if LookUpClass(AName) <> nil then
    raise EObjCRuntime.CreateFmt('class %s already exists', [AName]);
  FClass := objc_allocateClassPair(Superclass, PAnsiChar(AName), 0);
  if FClass = nil then
    raise EObjCRuntime.CreateFmt('objc_allocateClassPair failed for %s',
      [AName]);
end;

procedure TRuntimeClassBuilder.EnsureOpen;
begin
  if FRegistered then
    raise EObjCRuntime.CreateFmt('class %s is already registered', [FName]);
end;

function TRuntimeClassBuilder.AddPointerIvar(const AName: string): Boolean;
begin
  EnsureOpen;
  Result := class_addIvar(FClass, PAnsiChar(AName), SizeOf(Pointer),
    PointerIvarAlignmentLog2, PointerIvarTypeEncoding);
end;

function TRuntimeClassBuilder.AddMethod(const ASelector: string;
  AImplementation: TObjCMethodImplementation;
  const ATypeEncoding: string): Boolean;
begin
  EnsureOpen;
  Result := class_addMethod(FClass, Selector(ASelector),
    IMP(AImplementation), PAnsiChar(ATypeEncoding));
end;

function TRuntimeClassBuilder.AddProtocol(const AName: string): Boolean;
var
  Protocol: pobjc_protocol;
begin
  EnsureOpen;
  Protocol := objc_getProtocol(PAnsiChar(AName));
  Result := Protocol <> nil;
  if Result then
    Result := class_addProtocol(FClass, Protocol);
end;

function TRuntimeClassBuilder.Register: pobjc_class;
begin
  EnsureOpen;
  objc_registerClassPair(FClass);
  FRegistered := True;
  Result := FClass;
end;

{ Free functions }

function LookUpClass(const AName: string): pobjc_class;
begin
  Result := pobjc_class(objc_lookUpClass(PAnsiChar(AName)));
end;

function SelectorNamed(const AName: string): SEL;
begin
  Result := Selector(AName);
end;

function AllocateInstance(AClass: pobjc_class): id;
begin
  Result := nil;
  if AClass = nil then
    Exit;
  Result := MessageSendId(id(AClass), Selector('alloc'));
end;

function InstantiateClass(AClass: pobjc_class): id;
begin
  Result := AllocateInstance(AClass);
  if Result <> nil then
    Result := MessageSendId(Result, Selector('init'));
end;

procedure ReleaseInstance(AInstance: id);
begin
  if AInstance <> nil then
    MessageSendVoid(AInstance, Selector('release'));
end;

procedure SetPointerIvar(AInstance: id; const AIvarName: string;
  AValue: Pointer);
begin
  object_setInstanceVariable(AInstance, PAnsiChar(AIvarName), AValue);
end;

function GetPointerIvar(AInstance: id; const AIvarName: string): Pointer;
begin
  Result := nil;
  object_getInstanceVariable(AInstance, PAnsiChar(AIvarName), Result);
end;

function RespondsToSelector(AInstance: id; const ASelector: string): Boolean;
begin
  Result := (AInstance <> nil) and MessageSendBoolSel(AInstance,
    Selector('respondsToSelector:'), Selector(ASelector));
end;

function ClassImplementsSelector(AClass: pobjc_class;
  const ASelector: string): Boolean;
begin
  Result := (AClass <> nil)
    and (class_getInstanceMethod(AClass, Selector(ASelector)) <> nil);
end;

{$ENDIF}

end.
