unit Opname.Capture.ScreenCaptureKit;

{ Vendored from lantaarn's Lantaarn.Capture.ScreenCaptureKit (carried from
  the SoftKVM prototype's uScreenCaptureKit). What changed, and why, is in
  docs/porting-notes.md:

  - TSCKOutputHandler (the FPC-defined objcclass that made the linker
    demand -ld_classic) and TSCKCapture are gone. The stream output object
    is now built through the Objective-C runtime API in
    Opname.Capture.Stream, and this unit keeps only external declarations,
    which emit no method-list metadata.
  - Added: SCDisplay.frame, SCWindow.frame/owningApplication/isOnScreen/
    windowLayer, SCContentFilter.initWithDesktopIndependentWindow:,
    SCStreamConfiguration.setSourceRect:/setScalesToFit:, the
    SCStreamFrameInfoStatus attachment key and its status values.
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
  SysUtils, MacOSAll, CocoaAll, ctypes, Opname.Capture.CoreMedia;

{$linkframework ScreenCaptureKit}

const
  SCStreamOutputTypeScreen = 0;
  SCStreamOutputTypeAudio  = 1;

  { SCFrameStatus — value of the SCStreamFrameInfoStatus attachment on
    every video sample buffer. Only Complete frames carry pixels worth
    encoding; Idle/Blank/Suspended/Started/Stopped do not. }
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
  end;

{$ENDIF}

implementation

end.
