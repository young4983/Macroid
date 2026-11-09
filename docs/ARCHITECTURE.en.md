# Architecture and Android compatibility

Simplified Chinese: [ARCHITECTURE.md](ARCHITECTURE.md)

## Two product components

The Mac app, `io.macroid.desktop`, uses SwiftUI for the device, app, file, and settings views. AppKit hosts video windows with `AVSampleBufferDisplayLayer`. The client splits H.264 Annex B data into NAL units, builds CoreMedia video formats from SPS/PPS, converts access units to length-prefixed form, and hands them to the system decoder. It does not rely on FFmpeg, SDL, the official client, or the official server.

The menu bar uses the native SwiftUI `MenuBarExtra` menu style and a monochrome template icon based on the overlapping-window app mark. The main panel is a singleton `Window` with a fixed ID. Selecting a device from the menu opens the Apps tab immediately; the shared `AppModel` then connects and shows progress, results, or failures in that panel. Device discovery follows the app lifecycle, so closing the panel does not stop scanning or disconnect the device. Quitting follows the same cleanup path. The menu and panel share device, screen-power, and window state, and the menu can restore minimized windows.

The Android helper, `io.macroid.bridge`, has two execution domains:

1. The normal APK process provides Macroid Keyboard and an explicit broadcast receiver protected by the system DUMP permission. It has no launcher activity.
2. The Mac invokes `AgentMain` in the APK through ADB `app_process` as the shell user. It creates displays, launches apps, injects input, encodes and sends video, and accesses storage available to the shell.

The ordinary APK does not gain display-capture or input-injection privileges by declaring permissions. Authorization comes from the user approving the Mac for ADB debugging. Macroid does not request root or circumvent Android's permission model from the ordinary app process.

## Fusion and mirroring

A fusion window has its own VirtualDisplay, MediaCodec Surface, stream ID, and input display ID. The app runs in the phone's existing Android user and reuses its installation and data. This is not an Android emulator or an account-isolation container. Macroid starts the app on the secondary display with `am start --display`.

A mirror window captures the main display and injects input into display 0. The Mac reads from and writes to the same authenticated ADB-forwarded connection. Control JSON and video frames have explicit headers, and multiple video sessions share the connection by stream ID.

Each encoder has a dedicated output thread, and writes to the shared socket are serialized by complete frame. Mac transport and request state use one serial queue; UI and video display state run on the MainActor. There is no advanced congestion controller. USB and stable paired ADB network connections are the primary use cases.

## Encoder negotiation and diagnostics

Version 0.2 stopped forcing AVC Baseline because that setting made the Qualcomm/Oplus encoder on the OnePlus GM1910 fail during configuration with `0x80001001`. Macroid selects an encoder and parameters from Surface input, `VideoCapabilities`, size alignment, frame-rate, and bitrate limits. It prefers hardware, reduces the load after failure, and then tries a lower-resolution software encoder. Each attempt releases its own codec and Surface. SPS/PPS from output-format changes are sent instead of relying only on vendor codec-config buffers.

Actual negotiated parameters are returned by `stream.open`. The Mac app writes a bounded agent diagnostic log to `~/Library/Application Support/Macroid/Logs/agent.log`; session tokens and wireless pairing codes are not logged. If no first frame arrives in 12 seconds, the service reports an error and the window can retry.

## Wireless connections

The Devices tab accepts a pairing address, six-digit code, and connection address for Android's official ADB TLS pairing. The pairing code is not persisted; only a successfully connected address is remembered. A wireless device starts the same helper and authenticated protocol, with video carried over ADB TLS. Discovering a wireless device does not move a USB session; select and reconnect to the wireless device before unplugging USB.

## Android version branches

| Android version | Fusion display | Main-display capture |
| --- | --- | --- |
| Android 12 / API 31–32 | Legacy `createVirtualDisplay`, own-content/public, without the trusted flag unavailable to shell | SurfaceControl creates the capture display and projection |
| Android 13 / API 33 | Legacy display creation; trusted, display-group, and always-unlocked flags are added only when permissions allow | SurfaceControl |
| Android 14+ / API 34+ | Public `VirtualDisplayConfig`; own-focus is added when trusted-display permission is available | Hidden DisplayManager mirroring interface |

Input injection selects `InputManagerGlobal` or `InputManager` depending on the system. Hidden system interfaces are isolated in `ShellPlatform` and run only in the shell process. Lint suppressions for PrivateApi, BlockedPrivateApi, and WrongConstant in that bridge are deliberate and do not apply to the normal APK process. Android and OEM compatibility still needs ongoing maintenance.

Android 12 testing showed that a shell-created trusted display is rejected by `ADD_TRUSTED_DISPLAY`. The compatibility branch therefore uses a regular secondary display, which has been verified to launch another app and accept target input. This does not establish independent focus or complete lock-screen isolation. Newer systems also check the actual permission before trusted-display and always-unlocked flags are requested; if a device lacks the required permission, Macroid keeps the basic display and reports the actual `ownFocus` capability.

## Unicode, clipboard, and files

The Mac video view implements `NSTextInputClient` so macOS input methods can compose candidate text locally. After the user confirms Macroid Keyboard, the shell saves the previous default input method and switches to the helper IME. Submitted text is delivered through a protected broadcast and written with `InputConnection.commitText`. During a normal disconnect, the original keyboard is restored only if Macroid Keyboard is still selected, avoiding overwriting a keyboard the user chose in the meantime.

Without Macroid Keyboard, ASCII characters are mapped through `KeyCharacterMap` to target `KeyEvent`s. Special keys and editing shortcuts send Android key codes directly. IME focus on Android 12 / 13 is a compatibility limitation; Macroid does not claim fully independent keyboard instances for every window.

Clipboard transfer is explicit and manual. Android writes use the APK's protected broadcast. Reads use a `ClipboardManager` owned by `com.android.shell`; Macroid avoids using a cached system-context service under the `android` package, which can cause uid/package mismatches.

Shared-storage paths are canonicalized and checked before use. File uploads have a transfer ID, contiguous offset validation, a temporary file, and an atomic final commit. Cancellation and disconnect remove incomplete files. The protocol provides neither arbitrary shell execution nor access to app-private data.

## Internationalization

The Mac UI uses bundled `en.lproj` and `zh-Hans.lproj` catalogs. **Follow system** maps a preferred Chinese device language to Simplified Chinese and other languages to English; explicit overrides and the default system selection are stored in UserDefaults. The `LanguageSettings` observable publishes changes so the panel, menus, window toolbars, and existing status messages refresh without ending the device session. Known diagnostics from older Chinese Android helpers are translated on display, with paths, file names, encoder details, and unrecognized OEM error text preserved. The Android input-method label uses Android string resources so Android chooses the language from its own configuration.

## Future engineering

Audio, notifications, drag and drop, and virtual-device features can be added through explicit capability negotiation. Virtual camera and microphone support must be negotiated separately; Android 16 virtual-device capabilities must not be treated as a prerequisite for basic Android 12 fusion. A product release still needs a broader real-device OEM matrix, Apple Silicon runtime testing, release signing, and recovery and network-performance tests.

## Version 0.3 windows, reconfiguration, and screen power

Fusion uses an AppKit window with a native title bar and a freely resizable content area; phone mirroring keeps a proportional phone frame. Window position and size are stored by app. Always-on-top uses each window's floating level and is persisted without spanning every Space. The default fusion content size is 420×720 pt, approximately 1 pt per dp. The video pixel buffer and density scale together with Mac's backing scale: Retina uses 2× / 320 dpi, and compatibility mode uses 1.5× / 240 dpi. Moving between displays requests a new stream while preserving Android's dp layout. Fusion requests are capped at a 4096-pixel long edge and 12 Mbps, subject to actual encoder limits.

Window resize requests are coalesced to at most one per 200 ms; each stream has at most one outstanding request, and newer target sizes replace pending ones. Encoder generations are independent of the VirtualDisplay lifetime, so stopping an encoder does not destroy the app task. The replacement Surface stays on the same display; `VirtualDisplay.resize` delivers a normal Android configuration update and may recreate the Activity. Macroid does not force a tablet flag. When encoder limits reduce pixel resolution, density is scaled down with it to preserve dp. On failure, the service attempts to restore the previous valid size.

Transport delivers configuration events and video frames on the same main queue in socket order. During reconfiguration, `VideoRenderer` keeps the old frame visible until the new layer can display its first frame, then fades it in over 180 ms. Reduce Motion replaces it immediately. macOS 14.4+ uses `isReadyForDisplay`; older versions use rendering status. Input is disabled until the new frame is ready, and a generation number rejects late coordinates.

`DisplayManager.DisplayListener` tracks main-display dimensions and density. `WindowManager`'s `IRotationWatcher` also detects 180-degree rotations on systems that report no display-change event when width and height stay the same. Changes are coalesced and serialized with requests; orientation is read directly from `WindowManager` to avoid stale `DisplayInfo`. A mirror encoder is rebuilt when dimensions, density, or rotation change. Android 12 / 13 updates SurfaceControl projection; Android 14+ rebuilds the mirror VirtualDisplay and Surface without app tasks, avoiding stale buffers after repeated Surface replacement. When it receives a configuration boundary, the Mac updates the phone frame and keeps it within the visible screen. The rotation button switches between portrait and landscape while preserving the user's auto-rotate setting; the menu also provides an explicit auto-rotate action. If an app or system blocks rotation, the client displays a notice rather than faking the frame.

Screen power is managed per device and negotiated separately from `ownFocus` and `alwaysUnlocked`. `ShellPlatform` wraps the physical display token and SurfaceControl power APIs. On Android 14+, it may load `DisplayControl` and the `android_servers` JNI library through the system-server class loader. A separate `app_process` recovery guard holds a temporary wake lock and controls the panel; it restores the screen and releases the lock when the parent stdin pipe reaches EOF, including when the parent receives SIGKILL. If the guard alone is killed while the main agent remains alive, the agent monitors and restores it. This recovery guarantee does not cover a system reboot or every related process being killed simultaneously.
