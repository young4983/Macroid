# Macroid Wire v1

Simplified Chinese: [macroid-v1.md](macroid-v1.md)

This protocol is defined by Macroid. It is not compatible with AndroMeld's WebSocket/media protocol or scrcpy's socket format.

## Transport and lifecycle

The Mac installs `io.macroid.bridge` through ADB, gets its APK path, and runs it as shell uid 2000:

```text
CLASSPATH=<installed APK> app_process / io.macroid.bridge.AgentMain <socket-name> <token>
```

The service listens on the Android abstract Unix socket `macroid_<random>`. The Mac uses `adb -s <serial> forward tcp:0 localabstract:<socket-name>` to connect to a port bound only on the Mac. Each launch generates a fresh token, which is not persisted. The Android service does not listen on a LAN TCP port. Wireless mode carries the same protocol over paired Android wireless-debugging TLS. The client supports `adb pair` and `adb connect`; it does not enable legacy TCP port 5555. A single session cannot migrate automatically between USB and Wi-Fi.

The first frame must submit `hello` and the token within 10 seconds. The token is compared in constant time. The service accepts one connection and exits if it remains unconnected for 60 seconds. Closing the socket tears down video sessions, removes incomplete uploads, and restores an input method changed by the session.

ADB pairing and authorization provide device identity and transport security. The Wire layer provides session authentication but does not add TLS. Do not expose the locally forwarded port to the network.

## Frame format

All integers are unsigned big-endian. The fixed header is 16 bytes.

| Offset | Length | Meaning |
| --- | --- | --- |
| 0 | 4 | ASCII `MCRD` / `0x4d435244` |
| 4 | 1 | Version, fixed at `1` |
| 5 | 1 | Type: `1` JSON, `2` video |
| 6 | 2 | Flags; JSON is 0, video bit 0 is codec config, bit 1 is key frame |
| 8 | 4 | Video stream ID; JSON uses 0 |
| 12 | 4 | Payload size, at most 16 MiB |
| 16 | N | Payload |

Receivers must handle arbitrary splits within headers and payloads and multiple frames in one read. Validate size and version before allocating a complete payload.

JSON is a UTF-8 object. The first 8 bytes of a video payload are `presentationTimeUs` (big-endian int64), followed by MediaCodec H.264 Annex B data. Config frames contain SPS/PPS. The encoder chooses a supported AVC profile; Baseline is not forced, and the B-frame limit is 0.

## Requests and responses

Requests contain an increasing integer `id` and an `op`; other fields share the same object. `id=0` means no success response is required and is suitable for high-frequency input.

```json
{"id":1,"op":"hello","token":"<per-session token>"}
```

```json
{"id":1,"ok":true,"result":{"product":"Macroid","protocol":1,"sdk":31,"capabilities":{"ownFocus":false}}}
```

```json
{"id":2,"ok":false,"error":"human-readable reason"}
```

An error should not terminate an authenticated connection unless the frame cannot be parsed further. Async events contain an `event` field, for example:

```json
{"event":"stream.error","stream":1,"message":"encoder failure"}
```

## Operations

| Operation | Parameters | Result |
| --- | --- | --- |
| `hello` | `token` | Product, protocol version, SDK, device, and capabilities; first frame only |
| `ping` | none | `time` |
| `device.info` | none | Same device information as hello |
| `apps.launch` | `package` | Launch an app on display 0, for use when fusion mode is disabled |
| `apps.list` | none | `apps: [{package,name}]` for launchable apps |
| `apps.icon` | `package` | `png`, a Base64 PNG |
| `stream.open` | `stream,mode,package?,width?,height?,density?,fps?,bitrate?,maxSize?,configEvents?` | `stream,display,width,height,density,codec,mode,encoder,fps,generation` |
| `stream.resize` | `stream,width,height,density` | Same shape as stream.open; `restored,warning` when recovering the old size |
| `stream.rotate` | `stream,automatic?` | For mirror streams, switch portrait/landscape by default; `automatic=true` enables phone auto-rotate. Returns `rotation,rotationLocked,requestedRotation` |
| `device.screenPower` | `screenOff` (boolean) | Device-level, nonpersistent `screenOff` state |
| `stream.close` | `stream` | Empty object; idempotent |
| `stream.sync` | `stream` | Request a key frame |
| `input.pointer` | `stream,generation?,action,x,y,scrollX?,scrollY?` | Empty object |
| `input.key` | `stream,generation?,code,meta?` | Android KeyEvent code / meta |
| `input.text` | `stream,generation?,text` | Empty object; Unicode requires an enabled IME |
| `ime.enable` / `ime.disable` | none | `enabled` |
| `clipboard.set` | `text` | Empty object |
| `clipboard.get` | none | `text` |
| `files.list` | `path` | Canonical path and `entries` |
| `files.read` | `path,offset,count?` | `data,size,offset` |
| `files.upload.begin` | `path,size` | `transfer` |
| `files.upload.chunk` | `transfer,offset,data` | Next `offset` |
| `files.upload.finish` | `transfer` | Empty object |
| `files.upload.cancel` | `transfer` | Empty object |

The client selects a stream ID from 1–65535; up to four sessions can run concurrently. `mode=fusion` creates an own-content secondary display and starts `package`. `mode=mirror` captures display 0 and ignores the app parameter. Successful stream metadata is sent before the first video frame.

The default video settings are 720×1280, 240 dpi, 60 fps, and 6 Mbps. Fusion request dimensions must be 320–8192, and requested density must be 40–640 dpi. Encoder capabilities can reduce the actual pixel size. `maxSize` limits the encoded long edge (720–4096, default 1920). The current Mac client requests a 4096-pixel limit and 12 Mbps for fusion and scales pixels and density together with the display backing scale: Retina defaults to 2× / 320 dpi; compatibility mode uses 1.5× / 240 dpi. Both modes retain the same dp layout. Main-screen mirroring uses the actual aspect ratio and caps its long edge at 1920. Encoder alignment and size capabilities may further reduce the actual dimensions. On hardware-encoder failure, the service retries at 30 fps and long edges of 1920 or 1280, then attempts software encoding with long edges of 960 or 720 at 24 fps. AVC profile is not forced; B-frame limit is 0. `stream.open` returns actual `width`, `height`, `encoder`, and configured `fps`. Use this metadata for frame geometry and input coordinates. Concurrent resource use and vendor restrictions can still cause failure.

Coordinates use encoded-frame pixels and exclude Mac-side letterboxing. Main-screen input is mapped to the actual display size. Pointer actions are Android `0=DOWN,1=UP,2=MOVE,3=CANCEL,8=SCROLL`. Text is limited to 65,536 Java UTF-16 code units. Clients should explicitly enable the IME and must not change the user's keyboard automatically.

File data is Base64 encoded, with at most 196,608 raw bytes per chunk. The service only accesses canonical paths under the primary user's shared storage and rejects traversal and app-private paths. Uploads are written to a temporary file in the destination directory, validated at contiguous offsets, and committed after the expected size is verified and synchronized. Existing files are never overwritten. Disconnect removes incomplete uploads. Resuming an interrupted transfer is not supported.

Use negotiated capabilities for UI and future extensions instead of inferring every device feature from SDK level. Version 1 reports `audio=false` and `virtualCamera=false`. Unsupported protocol versions must be rejected; this protocol must not be interpreted as an official product protocol.

## Optional version 0.3 capabilities: resize and screen power

`hello.capabilities` adds `resize`, `streamConfig`, `screenPower`, `screenPowerReason`, and `alwaysUnlocked`; `ownFocus` remains separate. Missing fields mean false. `agentPid` is the Android agent PID for process-lifecycle diagnostics. Frame headers and video payloads are unchanged. Older clients that do not request configuration events continue to use fixed sizes.

A stream that can resize must request `configEvents=true` when opened. Whenever encoding begins, including the initial open, a successful resize, or recovery after failure, the service sends a configuration event before that generation's SPS/PPS and first key frame:

```json
{"event":"stream.config","stream":1,"display":7,"generation":2,"width":1440,"height":960,"density":240,"codec":"h264","encoder":"...","fps":60,"mode":"fusion"}
```

The service stops and joins the previous encoder thread before emitting the event. `generation` increases for the lifetime of an open stream. Events and video must be consumed in the same ordered client channel. First update geometry and decoder state; request-continuation scheduling is not a video boundary. A resize response can arrive after the new config event or video. Input can include a generation, and stale input is rejected. Cancel active pointer input before resizing and resume after the first new frame is ready.

Fusion retains its display ID and resizes the VirtualDisplay while replacing the encoder Surface. Reducing resolution scales density down to preserve the requested dp size, subject to minor rounding. Do not infer phone or tablet layout from encoded pixels. On resize failure, the service attempts the old size and sends a new config; a successful recovery response includes `restored=true` and `warning`. Failed recovery sends `stream.error`. Invalid dimensions are rejected before the encoder is stopped. Mirror streams and streams opened without config events cannot resize.

`device.screenPower` with `screenOff=true` turns off the physical panel without closing virtual displays or unlocking the phone. A valid stream must have produced a frame, and the phone must be interactive and unlocked. Detecting an API does not guarantee that every OEM accepts the operation. Failure is returned without committing the on-state. A state change is broadcast as `{"event":"device.screenPower","screenOff":true}` for every window. Closing or failing the last stream, disconnect, or normal app exit restores the panel. A separate recovery guard handles agent failure through parent-pipe EOF. A wake lock exists only for the screen-off session; the phone's permanent screen-timeout setting is unchanged. Physical panel power, independent focus, and lock-screen isolation must not be inferred from one another.

## Optional rotation capability

`hello.capabilities.rotation=true` indicates support for mirror-orientation tracking and `stream.rotate`. A mirror stream that changes orientation must use `configEvents=true`. The service tracks main-display orientation, size, and density; after stopping the previous encoder and rebuilding the video Surface, it sends a new `stream.config` followed by SPS/PPS and a key frame. Metadata includes `rotation` (0–3 in 90-degree steps) and `rotationLocked`. Android 12 / 13 updates SurfaceControl projection. Android 14+ rebuilds a mirror VirtualDisplay with no app tasks, preventing stale buffers after repeated Surface replacement. Input always targets display 0. Mirror streams do not accept `stream.resize`.

By default, `stream.rotate` toggles the current orientation between portrait and landscape (`rotation XOR 1`) so a device that cannot use reverse portrait is not left unresponsive. It preserves the phone's existing auto-rotate setting. `automatic=true` explicitly enables auto-rotate and sets `requestedRotation=-1`. The system or app may restrict orientation; use the resulting configuration and frame. Orientation state is also broadcast as `{"event":"device.rotation","rotation":1,"rotationLocked":false}`. This event is not a video configuration boundary. Serialize control changes and display reconfiguration; reject late input from old generations. Fusion app orientation is determined by the window aspect ratio and app layout.
