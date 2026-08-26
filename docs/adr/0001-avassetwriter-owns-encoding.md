# ADR-0001: AVAssetWriter owns encoding and muxing

## Status

Accepted.

## Context

The vendored capture core (from lantaarn) drove a VideoToolbox
compression session directly, converted AVCC NAL units to Annex-B, and
tagged frames for a WebSocket. A recorder needs the opposite: AVCC
samples in an `.mp4`/`.mov` container with a sample table and an `avcC`
box. Two ways to get there: keep the VideoToolbox session and write a
Pascal MP4 muxer (a pure-Pascal fMP4 muxer already exists in lantaarn's
browser viewer as a reference), or hand raw frames to AVAssetWriter and
let it own both encode and mux.

## Decision

knips appends ScreenCaptureKit's BGRA `CMSampleBuffer`s to an
`AVAssetWriterInput` configured for H.264. AVAssetWriter owns the
VideoToolbox session and the container. This is the pipeline Kap's
Aperture used. `Lantaarn.Capture.VideoEncoder` and `AudioEncoder` are
not carried; their bindings unit is, renamed `Knips.Capture.CoreMedia`,
because the stream wrapper and timing helpers still need CoreMedia types.

## Consequences

- No muxer to write, test, or debug; keyframe interval, bit rate, and
  profile are output-settings dictionary keys.
- Knips never sees NAL units, so the AVCC/Annex-B conversion and the
  SPS/PPS extraction in the carried encoder become dead weight — dropped.
- A future non-AVFoundation target (Windows) reimplements this layer
  behind `Knips.Options`; it does not reuse a shared muxer, because
  Media Foundation owns muxing there too.
- The fMP4-muxer path stays available in lantaarn's history if a
  frame-accurate, seek-free, crash-safe writer is ever wanted; AVAssetWriter's
  crash behaviour (a killed process can leave an unfinalised, unplayable
  file) is the known cost, mitigated only by finishing on clean stop.
