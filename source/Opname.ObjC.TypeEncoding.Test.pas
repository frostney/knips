program Opname.ObjC.TypeEncoding.Test;

{$I Shared.inc}

uses
  SysUtils,

  Opname.ObjC.TypeEncoding,
  TestingPascalLibrary;

type
  TEncodingTests = class(TTestSuite)
  public
    procedure SetupTests; override;
    procedure TestSelfAndCommandAreImplicit;
    procedure TestStreamOutputSelector;
    procedure TestIntegerWidthFollowsPointerSize;
    procedure TestReturnTypesLeadTheEncoding;
    procedure TestPointerAndCString;
  end;

procedure TEncodingTests.SetupTests;
begin
  Test('a no-argument void method encodes as v@:', TestSelfAndCommandAreImplicit);
  Test('stream:didOutputSampleBuffer:ofType: encodes id, pointer, NSInteger',
    TestStreamOutputSelector);
  Test('NSInteger encoding follows the pointer size',
    TestIntegerWidthFollowsPointerSize);
  Test('the return type leads the encoding', TestReturnTypesLeadTheEncoding);
  Test('pointer and C string arguments', TestPointerAndCString);
end;

procedure TEncodingTests.TestSelfAndCommandAreImplicit;
begin
  Expect<string>(MethodTypeEncoding(otVoid, [])).ToBe('v@:');
end;

procedure TEncodingTests.TestStreamOutputSelector;
var
  Expected: string;
begin
  Expected := 'v@:@^v' + TypeEncodingOf(otInteger);
  Expect<string>(MethodTypeEncoding(otVoid, [otObject, otPointer, otInteger]))
    .ToBe(Expected);
end;

procedure TEncodingTests.TestIntegerWidthFollowsPointerSize;
begin
  if SizeOf(NativeInt) = 8 then
  begin
    Expect<string>(TypeEncodingOf(otInteger)).ToBe('q');
    Expect<string>(TypeEncodingOf(otUnsignedInteger)).ToBe('Q');
  end
  else
  begin
    Expect<string>(TypeEncodingOf(otInteger)).ToBe('l');
    Expect<string>(TypeEncodingOf(otUnsignedInteger)).ToBe('L');
  end;
end;

procedure TEncodingTests.TestReturnTypesLeadTheEncoding;
begin
  Expect<string>(MethodTypeEncoding(otObject, [otObject])).ToBe('@@:@');
  Expect<string>(MethodTypeEncoding(otDouble, [])).ToBe('d@:');
  Expect<string>(Copy(MethodTypeEncoding(otBool, []), 2, 2)).ToBe('@:');
end;

procedure TEncodingTests.TestPointerAndCString;
begin
  Expect<string>(MethodTypeEncoding(otVoid, [otPointer, otCString]))
    .ToBe('v@:^v*');
end;

begin
  TestRunnerProgram.AddSuite(TEncodingTests.Create('MethodTypeEncoding'));
  TestRunnerProgram.Run;
  ExitCode := TestResultToExitCode;
end.
