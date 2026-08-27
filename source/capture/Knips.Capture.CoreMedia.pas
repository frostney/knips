unit Knips.Capture.CoreMedia;

{ Vendored from lantaarn's Lantaarn.Capture.VideoToolbox (itself carried from
  the SoftKVM prototype's uVideoToolbox). Renamed to say what it binds —
  CoreVideo, CoreMedia, VideoToolbox and GCD — since knips's default
  pipeline lets AVAssetWriter own the VideoToolbox session. Contents are
  carried as-is; knips's additions are in the marked block at the end of
  the interface. See docs/porting-notes.md. }

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

{$IFDEF DARWIN}
uses
  MacOSAll, ctypes;

{ ======== CoreVideo types ======== }
type
  CVPixelBufferRef = Pointer;
  CVReturn = cint32;
  CVOptionFlags = cuint64;

const
  kCVPixelFormatType_32BGRA = $42475241;  { 'BGRA' }
  kCVReturn_Success = 0;
  kCVPixelBufferLock_ReadOnly = 1;

var
  kCVPixelBufferPixelFormatTypeKey: CFStringRef;
    external name '_kCVPixelBufferPixelFormatTypeKey';
  kCFAllocatorNull: CFAllocatorRef;
    external name '_kCFAllocatorNull';

{ CVPixelBuffer functions }
function CVPixelBufferCreate(
  allocator: CFAllocatorRef;
  width: csize_t;
  height: csize_t;
  pixelFormatType: OSType;
  pixelBufferAttributes: CFDictionaryRef;
  pixelBufferOut: Pointer { ^CVPixelBufferRef }
): CVReturn; external name '_CVPixelBufferCreate';

function CVPixelBufferLockBaseAddress(
  pixelBuffer: CVPixelBufferRef;
  lockFlags: CVOptionFlags
): CVReturn; external name '_CVPixelBufferLockBaseAddress';

function CVPixelBufferUnlockBaseAddress(
  pixelBuffer: CVPixelBufferRef;
  unlockFlags: CVOptionFlags
): CVReturn; external name '_CVPixelBufferUnlockBaseAddress';

function CVPixelBufferGetBaseAddress(
  pixelBuffer: CVPixelBufferRef
): Pointer; external name '_CVPixelBufferGetBaseAddress';

function CVPixelBufferGetBytesPerRow(
  pixelBuffer: CVPixelBufferRef
): csize_t; external name '_CVPixelBufferGetBytesPerRow';

function CVPixelBufferGetWidth(
  pixelBuffer: CVPixelBufferRef
): csize_t; external name '_CVPixelBufferGetWidth';

function CVPixelBufferGetHeight(
  pixelBuffer: CVPixelBufferRef
): csize_t; external name '_CVPixelBufferGetHeight';

procedure CVPixelBufferRelease(
  pixelBuffer: CVPixelBufferRef
); external name '_CVPixelBufferRelease';

{ ======== CoreMedia types ======== }
type
  CMTime = record
    value: cint64;
    timescale: cint32;
    flags: cuint32;
    epoch: cint64;
  end;

  CMSampleBufferRef = Pointer;
  CMFormatDescriptionRef = Pointer;
  CMBlockBufferRef = Pointer;
  CMItemCount = NativeInt;

const
  kCMTimeFlags_Valid              = 1;
  kCMTimeFlags_HasBeenRounded     = 2;
  kCMTimeFlags_PositiveInfinity   = 4;
  kCMTimeFlags_NegativeInfinity   = 8;
  kCMTimeFlags_Indefinite         = 16;

function CMTimeMake(value: cint64; timescale: cint32): CMTime;
  external name '_CMTimeMake';

function CMSampleBufferGetDataBuffer(
  sbuf: CMSampleBufferRef
): CMBlockBufferRef; external name '_CMSampleBufferGetDataBuffer';

function CMSampleBufferGetFormatDescription(
  sbuf: CMSampleBufferRef
): CMFormatDescriptionRef; external name '_CMSampleBufferGetFormatDescription';

function CMBlockBufferGetDataPointer(
  theBuffer: CMBlockBufferRef;
  offset: csize_t;
  lengthAtOffsetOut: Pcsize_t;
  totalLengthOut: Pcsize_t;
  dataPointerOut: PPointer
): OSStatus; external name '_CMBlockBufferGetDataPointer';

function CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
  videoDesc: CMFormatDescriptionRef;
  parameterSetIndex: csize_t;
  parameterSetPointerOut: PPointer;
  parameterSetSizeOut: Pcsize_t;
  parameterSetCountOut: Pcsize_t;
  NALUnitHeaderLengthOut: PCint32
): OSStatus; external name '_CMVideoFormatDescriptionGetH264ParameterSetAtIndex';

function CMSampleBufferGetSampleAttachmentsArray(
  sbuf: CMSampleBufferRef;
  createIfNecessary: Boolean
): CFArrayRef; external name '_CMSampleBufferGetSampleAttachmentsArray';

function CMSampleBufferGetImageBuffer(
  sbuf: CMSampleBufferRef
): CVPixelBufferRef; external name '_CMSampleBufferGetImageBuffer';

{ ======== VideoToolbox types ======== }
type
  VTCompressionSessionRef = Pointer;
  VTEncodeInfoFlags = cuint32;

  VTCompressionOutputCallback = procedure(
    outputCallbackRefCon: Pointer;
    sourceFrameRefCon: Pointer;
    status: OSStatus;
    infoFlags: VTEncodeInfoFlags;
    sampleBuffer: CMSampleBufferRef
  ); cdecl;

const
  kCMVideoCodecType_H264 = $61766331;  { 'avc1' }
  kVTEncodeInfo_Asynchronous = 1;
  noErr = 0;

function VTCompressionSessionCreate(
  allocator: CFAllocatorRef;
  width: cint32;
  height: cint32;
  codecType: cuint32;  { CMVideoCodecType }
  encoderSpecification: CFDictionaryRef;
  sourceImageBufferAttributes: CFDictionaryRef;
  compressedDataAllocator: CFAllocatorRef;
  outputCallback: VTCompressionOutputCallback;
  outputCallbackRefCon: Pointer;
  compressionSessionOut: Pointer { ^VTCompressionSessionRef }
): OSStatus; external name '_VTCompressionSessionCreate';

function VTCompressionSessionEncodeFrame(
  session: VTCompressionSessionRef;
  imageBuffer: CVPixelBufferRef;
  presentationTimeStamp: CMTime;
  duration: CMTime;
  frameProperties: CFDictionaryRef;
  sourceFrameRefCon: Pointer;
  infoFlagsOut: Pointer { ^VTEncodeInfoFlags }
): OSStatus; external name '_VTCompressionSessionEncodeFrame';

function VTCompressionSessionCompleteFrames(
  session: VTCompressionSessionRef;
  completeUntilPresentationTimeStamp: CMTime
): OSStatus; external name '_VTCompressionSessionCompleteFrames';

procedure VTCompressionSessionInvalidate(
  session: VTCompressionSessionRef
); external name '_VTCompressionSessionInvalidate';

function VTSessionSetProperty(
  session: Pointer; { VTSession - base type for compression/decompression }
  propertyKey: CFStringRef;
  propertyValue: CFTypeRef
): OSStatus; external name '_VTSessionSetProperty';

{ ======== Property key globals ======== }
var
  kVTCompressionPropertyKey_RealTime: CFStringRef;
    external name '_kVTCompressionPropertyKey_RealTime';
  kVTCompressionPropertyKey_ProfileLevel: CFStringRef;
    external name '_kVTCompressionPropertyKey_ProfileLevel';
  kVTCompressionPropertyKey_AverageBitRate: CFStringRef;
    external name '_kVTCompressionPropertyKey_AverageBitRate';
  kVTCompressionPropertyKey_MaxKeyFrameInterval: CFStringRef;
    external name '_kVTCompressionPropertyKey_MaxKeyFrameInterval';
  kVTCompressionPropertyKey_AllowFrameReordering: CFStringRef;
    external name '_kVTCompressionPropertyKey_AllowFrameReordering';
  kVTCompressionPropertyKey_MaxFrameDelayCount: CFStringRef;
    external name '_kVTCompressionPropertyKey_MaxFrameDelayCount';
  kVTCompressionPropertyKey_ExpectedFrameRate: CFStringRef;
    external name '_kVTCompressionPropertyKey_ExpectedFrameRate';

  kVTProfileLevel_H264_Baseline_AutoLevel: CFStringRef;
    external name '_kVTProfileLevel_H264_Baseline_AutoLevel';

  kVTProfileLevel_H264_Main_AutoLevel: CFStringRef;
    external name '_kVTProfileLevel_H264_Main_AutoLevel';

  kCMSampleAttachmentKey_NotSync: CFStringRef;
    external name '_kCMSampleAttachmentKey_NotSync';

  kVTEncodeFrameOptionKey_ForceKeyFrame: CFStringRef;
    external name '_kVTEncodeFrameOptionKey_ForceKeyFrame';

{ ======== VideoToolbox Decompression (decoder) ======== }
type
  VTDecompressionSessionRef = Pointer;
  VTDecodeInfoFlags = cuint32;
  VTDecodeFrameFlags = cuint32;

  CMSampleTimingInfo = record
    duration: CMTime;
    presentationTimeStamp: CMTime;
    decodeTimeStamp: CMTime;
  end;

  { Decompression output callback — called for each decoded frame }
  VTDecompressionOutputCallback = procedure(
    decompressionOutputRefCon: Pointer;
    sourceFrameRefCon: Pointer;
    status: OSStatus;
    infoFlags: VTDecodeInfoFlags;
    imageBuffer: CVPixelBufferRef;
    presentationTimeStamp: CMTime;
    presentationDuration: CMTime
  ); cdecl;

  { VTDecompressionOutputCallbackRecord — passed to VTDecompressionSessionCreate }
  VTDecompressionOutputCallbackRecord = record
    decompressionOutputCallback: VTDecompressionOutputCallback;
    decompressionOutputRefCon: Pointer;
  end;

const
  kVTDecodeFrame_EnableAsynchronousDecompression = 1;
  kVTDecodeFrame_EnableTemporalProcessing = 4;

  kCMBlockBufferAssureMemoryNowFlag = 1;

function VTDecompressionSessionCreate(
  allocator: CFAllocatorRef;
  videoFormatDescription: CMFormatDescriptionRef;
  videoDecoderSpecification: CFDictionaryRef;
  destinationImageBufferAttributes: CFDictionaryRef;
  outputCallback: Pointer; { ^VTDecompressionOutputCallbackRecord }
  decompressionSessionOut: Pointer { ^VTDecompressionSessionRef }
): OSStatus; external name '_VTDecompressionSessionCreate';

function VTDecompressionSessionDecodeFrame(
  session: VTDecompressionSessionRef;
  sampleBuffer: CMSampleBufferRef;
  decodeFlags: VTDecodeFrameFlags;
  sourceFrameRefCon: Pointer;
  infoFlagsOut: Pointer { ^VTDecodeInfoFlags }
): OSStatus; external name '_VTDecompressionSessionDecodeFrame';

function VTDecompressionSessionWaitForAsynchronousFrames(
  session: VTDecompressionSessionRef
): OSStatus; external name '_VTDecompressionSessionWaitForAsynchronousFrames';

procedure VTDecompressionSessionInvalidate(
  session: VTDecompressionSessionRef
); external name '_VTDecompressionSessionInvalidate';

{ ======== CMVideoFormatDescription creation from H.264 parameter sets ======== }
function CMVideoFormatDescriptionCreateFromH264ParameterSets(
  allocator: CFAllocatorRef;
  parameterSetCount: csize_t;
  parameterSetPointers: PPointer; { array of PByte }
  parameterSetSizes: Pcsize_t;   { array of csize_t }
  NALUnitHeaderLength: cint32;
  formatDescriptionOut: Pointer { ^CMFormatDescriptionRef }
): OSStatus; external name '_CMVideoFormatDescriptionCreateFromH264ParameterSets';

{ ======== CMBlockBuffer creation ======== }
function CMBlockBufferCreateWithMemoryBlock(
  structureAllocator: CFAllocatorRef;
  memoryBlock: Pointer;
  blockLength: csize_t;
  blockAllocator: CFAllocatorRef;
  customBlockSource: Pointer;
  offsetToData: csize_t;
  dataLength: csize_t;
  flags: cuint32;
  blockBufferOut: Pointer { ^CMBlockBufferRef }
): OSStatus; external name '_CMBlockBufferCreateWithMemoryBlock';

{ ======== CMSampleBuffer creation ======== }
function CMSampleBufferCreateReady(
  allocator: CFAllocatorRef;
  dataBuffer: CMBlockBufferRef;
  formatDescription: CMFormatDescriptionRef;
  sampleCount: CMItemCount;
  sampleTimingEntryCount: CMItemCount;
  sampleTimingArray: Pointer; { ^CMSampleTimingInfo }
  sampleSizeEntryCount: CMItemCount;
  sampleSizeArray: Pcsize_t;
  sampleBufferOut: Pointer { ^CMSampleBufferRef }
): OSStatus; external name '_CMSampleBufferCreateReady';

procedure CMSampleBufferInvalidate(
  sbuf: CMSampleBufferRef
); external name '_CMSampleBufferInvalidate';

{ ======== CFRelease for CoreMedia objects ======== }
procedure CMBlockBufferRelease(
  buf: CMBlockBufferRef
); external name '_CFRelease';

procedure CMSampleBufferRelease(
  sbuf: CMSampleBufferRef
); external name '_CFRelease';

procedure CMFormatDescriptionRelease(
  desc: CMFormatDescriptionRef
); external name '_CFRelease';

function CVPixelBufferRetain(
  pixelBuffer: CVPixelBufferRef
): CVPixelBufferRef; external name '_CVPixelBufferRetain';

{ ======== GCD dispatch queue (for ScreenCaptureKit) ======== }
type
  dispatch_queue_t = Pointer;

function dispatch_queue_create(
  lab: PAnsiChar;
  attr: Pointer
): dispatch_queue_t; external name '_dispatch_queue_create';

procedure dispatch_release(
  queue: dispatch_queue_t
); external name '_dispatch_release';

{ ======== knips additions (not in the vendored original) ======== }

{ Presentation timing straight from the sample buffer. SCK delivers frames
  only when content changes, so a recorder must take timestamps from the
  buffer rather than counting frames (the streaming encoder's approach). }
function CMSampleBufferGetPresentationTimeStamp(
  sbuf: CMSampleBufferRef
): CMTime; external name '_CMSampleBufferGetPresentationTimeStamp';

function CMSampleBufferGetDuration(
  sbuf: CMSampleBufferRef
): CMTime; external name '_CMSampleBufferGetDuration';

function CMSampleBufferDataIsReady(
  sbuf: CMSampleBufferRef
): Boolean; external name '_CMSampleBufferDataIsReady';

function CMSampleBufferIsValid(
  sbuf: CMSampleBufferRef
): Boolean; external name '_CMSampleBufferIsValid';

function CMTimeGetSeconds(
  time: CMTime
): Float64; external name '_CMTimeGetSeconds';

{ The clock ScreenCaptureKit stamps its sample buffers against. The event
  sidecar (Knips.Recording.Sidecar) samples the cursor on the main thread
  and has to place those samples on the movie's own timeline; reading the
  same clock the frame PTS comes from is what makes that exact rather than
  approximate — no wall clock, no elapsed-time estimate, no drift. }
type
  CMClockRef = Pointer;

function CMClockGetHostTimeClock: CMClockRef;
  external name '_CMClockGetHostTimeClock';

function CMClockGetTime(
  clock: CMClockRef
): CMTime; external name '_CMClockGetTime';

{ Seconds on the host clock, right now. }
function HostClockSeconds: Double;

function CMTimeCompare(
  time1: CMTime;
  time2: CMTime
): cint32; external name '_CMTimeCompare';

{ What a pixel buffer actually holds. Big Cursor composites into the
  frame's own bytes on the capture queue (Knips.Recording.CursorOverlay),
  where a wrong assumption about the layout is a write into someone
  else's memory rather than a wrong colour: the stream is configured for
  32BGRA, and these two are what let that be checked instead of trusted. }
function CVPixelBufferGetPixelFormatType(
  pixelBuffer: CVPixelBufferRef
): OSType; external name '_CVPixelBufferGetPixelFormatType';

function CVPixelBufferIsPlanar(
  pixelBuffer: CVPixelBufferRef
): Boolean; external name '_CVPixelBufferIsPlanar';

{ Audio format inspection, for the silence check in
  Knips.Export.MovieWriter: a track that was enabled and came out silent is
  the failure nobody notices until the take is unrepeatable, and reading
  the samples is the only way to know. The format description is what says
  whether the bytes in the block buffer are 32-bit floats — nothing guesses
  at a layout it has not been told. }
type
  AudioStreamBasicDescription = record
    mSampleRate: Float64;
    mFormatID: UInt32;
    mFormatFlags: UInt32;
    mBytesPerPacket: UInt32;
    mFramesPerPacket: UInt32;
    mBytesPerFrame: UInt32;
    mChannelsPerFrame: UInt32;
    mBitsPerChannel: UInt32;
    mReserved: UInt32;
  end;
  PAudioStreamBasicDescription = ^AudioStreamBasicDescription;

const
  { 'lpcm' — kAudioFormatLinearPCM from CoreAudioBaseTypes.h. }
  kKnipsAudioFormatLinearPCM = $6C70636D;
  { kAudioFormatFlagIsFloat. }
  kKnipsAudioFormatFlagIsFloat = 1;

{ Returns nil for a description that is not audio. The pointer belongs to
  the format description and must not be freed. }
function CMAudioFormatDescriptionGetStreamBasicDescription(
  desc: CMFormatDescriptionRef
): PAudioStreamBasicDescription;
  external name '_CMAudioFormatDescriptionGetStreamBasicDescription';

{ ======== Helper to create CMTime inline ======== }
function MakeCMTime(value: cint64; timescale: cint32): CMTime;

{$ENDIF}

implementation

{$IFDEF DARWIN}

function MakeCMTime(value: cint64; timescale: cint32): CMTime;
begin
  Result.value := value;
  Result.timescale := timescale;
  Result.flags := kCMTimeFlags_Valid;
  Result.epoch := 0;
end;

function HostClockSeconds: Double;
begin
  Result := CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock));
end;

{$ENDIF}

end.
