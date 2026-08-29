unit Knips.Capture.ScreenCaptureKit;

{ Vendored from lantaarn's Lantaarn.Capture.ScreenCaptureKit (carried from
  the SoftKVM prototype's uScreenCaptureKit). What changed, and why, is in
  docs/porting-notes.md:

  - TSCKOutputHandler (the FPC-defined objcclass that made the linker
    demand -ld_classic) and TSCKCapture are gone. The stream output object
    is now built through the Objective-C runtime API in
    Knips.Capture.Stream, and this unit keeps only external declarations,
    which emit no method-list metadata.
  - Added: SCDisplay.frame, SCWindow.frame/owningApplication/isOnScreen/
    windowLayer, SCRunningApplication.processID,
    SCContentFilter.initWithDesktopIndependentWindow:,
    SCStreamConfiguration.setSourceRect:/setScalesToFit:, the
    SCStreamFrameInfoStatus attachment key and its status values.
  - Added: SCStreamOutputTypeMicrophone and
    SCStreamConfiguration.setCaptureMicrophone:/
    setMicrophoneCaptureDeviceID: (macOS 15).
  - Added: SCStream.updateConfiguration:completionHandler:, which is what
    makes Zoom on Click and Follow Mouse possible without touching the
    writer's dimensions.
  - The block types and async completion pattern are unchanged.

  Everything else is carried verbatim, including formatting. }

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec2}
{$modeswitch cblocks}
{$ENDIF}

interface

{$IFDEF DARWIN}
uses
  SysUtils, MacOSAll, CocoaAll, ctypes, Knips.Capture.CoreMedia;

{$linkframework ScreenCaptureKit}

const
  SCStreamOutputTypeScreen = 0;
  SCStreamOutputTypeAudio  = 1;

  { ======== knips additions (not in the vendored original) ======== }

  { SCStreamOutputTypeMicrophone, macOS 15. Verified against SCStream.h in
    the MacOSX.sdk of Xcode's current toolchain: the SCStreamOutputType
    NS_ENUM lists Screen, Audio, Microphone with no explicit values, so
    Microphone is 2. Buffers arrive in the microphone device's own native
    format, not the sampleRate/channelCount set for system audio. }
  SCStreamOutputTypeMicrophone = 2;

  { SCFrameStatus — value of the SCStreamFrameInfoStatus attachment on
    every video sample buffer. Only Complete frames carry pixels worth
    encoding; Idle/Blank/Suspended/Started/Stopped do not.

    The whole enum is transcribed although knips compares against
    Complete and nothing else. That is deliberate and DOCUMENTARY: the
    five unused names are what make the one used name a filter rather
    than a magic zero, and a reader chasing "why was this frame dropped"
    can put the number the attachment carried against them. The same
    goes for the AVFoundation status enums transcribed in
    Knips.Export.MovieReader, .MovieWriter and .MovieTrim. }
  SCFrameStatusComplete  = 0;
  SCFrameStatusIdle      = 1;
  SCFrameStatusBlank     = 2;
  SCFrameStatusSuspended = 3;
  SCFrameStatusStarted   = 4;
  SCFrameStatusStopped   = 5;

var
  { NSString* const, toll-free bridged to CFStringRef so the attachment
    lookup can stay in CoreFoundation on the capture thread. }
  SCStreamFrameInfoStatus: CFStringRef;
    external name '_SCStreamFrameInfoStatus';

type
  { Forward declarations for SCK classes }
  SCDisplay = objcclass;
  SCWindow = objcclass;
  SCRunningApplication = objcclass;
  SCShareableContent = objcclass;
  SCContentFilter = objcclass;
  SCStreamConfiguration = objcclass;
  SCStream = objcclass;

  SCStreamOutputType = NSInteger;

  { ======== Block types for SCK async calls ======== }
  TSCContentBlock = reference to procedure(content: id;
    error: id); cdecl; cblock;
  TSCErrorBlock = reference to procedure(error: id); cdecl; cblock;

  { ======== SCK External Class Declarations ======== }

  SCDisplay = objcclass external (NSObject)
    function displayID: UInt32; message 'displayID';
    function width: NSInteger; message 'width';
    function height: NSInteger; message 'height';
    function frame: CGRect; message 'frame';
  end;

  SCRunningApplication = objcclass external (NSObject)
    function bundleIdentifier: NSString; message 'bundleIdentifier';
    function applicationName: NSString; message 'applicationName';
    { knips addition: pid_t, which is a 32-bit signed int on Darwin.
      applicationName is a display name — 'Knips' under the bundle,
      'knips-bin' from the shell — so the pid is the only reliable way
      to tell our own windows apart from everybody else's. }
    function processID: cint32; message 'processID';
  end;

  SCWindow = objcclass external (NSObject)
    function windowID: CGWindowID; message 'windowID';
    function title: NSString; message 'title';
    function frame: CGRect; message 'frame';
    function owningApplication: SCRunningApplication; message 'owningApplication';
    function isOnScreen: ObjCBOOL; message 'isOnScreen';
    function windowLayer: NSInteger; message 'windowLayer';
  end;

  SCShareableContent = objcclass external (NSObject)
    function displays: NSArray; message 'displays';
    function windows: NSArray; message 'windows';
    function applications: NSArray; message 'applications';
    class procedure getShareableContentExcludingDesktopWindows_onScreenWindowsOnly_completionHandler(
      excludeDesktopWindows: ObjCBOOL;
      onScreenWindowsOnly: ObjCBOOL;
      completionHandler: TSCContentBlock
    ); message 'getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:';
  end;

  SCContentFilter = objcclass external (NSObject)
    function initWithDisplay_excludingWindows(display: SCDisplay;
      excluded: NSArray): id;
      message 'initWithDisplay:excludingWindows:';
    function initWithDesktopIndependentWindow(window: SCWindow): id;
      message 'initWithDesktopIndependentWindow:';
  end;

  SCStreamConfiguration = objcclass external (NSObject)
    procedure setWidth(w: NSInteger); message 'setWidth:';
    function width: NSInteger; message 'width';
    procedure setHeight(h: NSInteger); message 'setHeight:';
    function height: NSInteger; message 'height';
    procedure setMinimumFrameInterval(interval: CMTime); message 'setMinimumFrameInterval:';
    procedure setPixelFormat(fmt: OSType); message 'setPixelFormat:';
    procedure setShowsCursor(show: ObjCBOOL); message 'setShowsCursor:';
    procedure setQueueDepth(depth: NSInteger); message 'setQueueDepth:';
    procedure setCapturesAudio(captures: ObjCBOOL); message 'setCapturesAudio:';
    procedure setSampleRate(rate: NSInteger); message 'setSampleRate:';
    procedure setChannelCount(count: NSInteger); message 'setChannelCount:';
    { Region of the filtered content to capture, in points }
    procedure setSourceRect(rect: CGRect); message 'setSourceRect:';
    procedure setScalesToFit(scales: ObjCBOOL); message 'setScalesToFit:';
    { knips addition: microphone capture, macOS 15. captureMicrophone is
      BOOL and defaults to NO; microphoneCaptureDeviceID is a nullable
      NSString* holding an AVCaptureDevice uniqueID, and the system
      default microphone is used when it is not set. }
    procedure setCaptureMicrophone(captures: ObjCBOOL);
      message 'setCaptureMicrophone:';
    procedure setMicrophoneCaptureDeviceID(deviceID: NSString);
      message 'setMicrophoneCaptureDeviceID:';
  end;

  { SCStream }
  SCStream = objcclass external (NSObject)
    function initWithFilter_configuration_delegate(
      filter: SCContentFilter;
      configuration: SCStreamConfiguration;
      delegate: id): id;
      message 'initWithFilter:configuration:delegate:';
    function addStreamOutput_type_sampleHandlerQueue_error(
      output: id; typ: SCStreamOutputType;
      queue: dispatch_queue_t; error: NSErrorPtr): ObjCBOOL;
      message 'addStreamOutput:type:sampleHandlerQueue:error:';
    procedure startCaptureWithCompletionHandler(handler: TSCErrorBlock);
      message 'startCaptureWithCompletionHandler:';
    procedure stopCaptureWithCompletionHandler(handler: TSCErrorBlock);
      message 'stopCaptureWithCompletionHandler:';
    { knips addition: live reconfiguration of a running stream. Verified
      against SCStream.h in the MacOSX.sdk of Xcode's current toolchain —
      the declaration sits inside @interface SCStream, which is annotated
      API_AVAILABLE(macos(12.3)) with no availability of its own, so it is
      as old as SCStream itself. The completion handler is nullable and
      takes NSError*, exactly like the two above, so it takes the same
      block type and the same global cdecl procedure shape.

      This is what Zoom on Click and Follow Mouse are built on: the output
      width and height are fixed by AVAssetWriter and never change, and
      only sourceRect moves. }
    procedure updateConfiguration_completionHandler(
      configuration: SCStreamConfiguration; handler: TSCErrorBlock);
      message 'updateConfiguration:completionHandler:';
  end;

{$ENDIF}

implementation

end.
