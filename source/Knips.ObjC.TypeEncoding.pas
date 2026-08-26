unit Knips.ObjC.TypeEncoding;

// Objective-C method type encodings for classes built through the
// runtime API (class_addMethod needs one per method). The encoding is a
// plain string — return type first, then the implicit self ('@') and
// _cmd (':'), then each declared argument — so this unit is pure Pascal
// and unit-tested on every platform. The runtime only uses these for
// argument-frame bookkeeping; a wrong one corrupts message forwarding,
// so the builder exists to keep them out of hand-typed literals.

{$I Shared.inc}

interface

type
  TObjCType = (
    otVoid,
    otObject,           // id / any objcclass
    otClass,            // Class
    otSelector,         // SEL
    otPointer,          // any C pointer (^v)
    otInteger,          // NSInteger — long on 64-bit
    otUnsignedInteger,  // NSUInteger
    otBool,             // ObjC BOOL
    otDouble,
    otFloat,
    otCString,          // char*
    otPoint,            // CGPoint / NSPoint, by value
    otSize,             // CGSize / NSSize, by value
    otRect);            // CGRect / NSRect, by value (NSView's drawRect:)

function TypeEncodingOf(AType: TObjCType): string;

// Encoding for an instance or class method with the given return type
// and declared arguments. Self and _cmd are added automatically.
function MethodTypeEncoding(AReturn: TObjCType;
  const AArguments: array of TObjCType): string;

implementation

const
  // 'q'/'Q' when NSInteger is 64-bit, 'l'/'L' otherwise.
  IntegerEncoding64 = 'q';
  UnsignedEncoding64 = 'Q';
  IntegerEncoding32 = 'l';
  UnsignedEncoding32 = 'L';
  // BOOL is a C bool on Apple silicon and 64-bit iOS ('B'), a signed
  // char ('c') on Intel macOS.
  BoolEncodingAppleSilicon = 'B';
  BoolEncodingIntel = 'c';
  // Struct encodings are `{Name=fields}`. CGFloat is a double on 64-bit,
  // a single on 32-bit; the geometry structs are named after their
  // CoreGraphics types, which is what the ObjC runtime records for
  // AppKit's own -drawRect:, -mouseDown: and friends.
  {$IFDEF CPU64}
  FloatEncoding = 'd';
  {$ELSE}
  FloatEncoding = 'f';
  {$ENDIF}
  PointEncoding = '{CGPoint=' + FloatEncoding + FloatEncoding + '}';
  SizeEncoding = '{CGSize=' + FloatEncoding + FloatEncoding + '}';
  RectEncoding = '{CGRect=' + PointEncoding + SizeEncoding + '}';

function TypeEncodingOf(AType: TObjCType): string;
begin
  case AType of
    otVoid: Result := 'v';
    otObject: Result := '@';
    otClass: Result := '#';
    otSelector: Result := ':';
    otPointer: Result := '^v';
    otInteger:
      {$IFDEF CPU64}
      Result := IntegerEncoding64;
      {$ELSE}
      Result := IntegerEncoding32;
      {$ENDIF}
    otUnsignedInteger:
      {$IFDEF CPU64}
      Result := UnsignedEncoding64;
      {$ELSE}
      Result := UnsignedEncoding32;
      {$ENDIF}
    otBool:
      {$IFDEF CPUAARCH64}
      Result := BoolEncodingAppleSilicon;
      {$ELSE}
      Result := BoolEncodingIntel;
      {$ENDIF}
    otDouble: Result := 'd';
    otFloat: Result := 'f';
    otCString: Result := '*';
    otPoint: Result := PointEncoding;
    otSize: Result := SizeEncoding;
    otRect: Result := RectEncoding;
  else
    Result := '?';
  end;
end;

function MethodTypeEncoding(AReturn: TObjCType;
  const AArguments: array of TObjCType): string;
var
  I: Integer;
begin
  Result := TypeEncodingOf(AReturn) + TypeEncodingOf(otObject)
    + TypeEncodingOf(otSelector);
  for I := Low(AArguments) to High(AArguments) do
    Result := Result + TypeEncodingOf(AArguments[I]);
end;

end.
