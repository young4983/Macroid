# Test log

Simplified Chinese: [TESTING.md](TESTING.md)

Latest test date: 2026-11-09. This page summarizes recent changes and preserves the historical 0.3 / 0.2 / 0.1 validation scope.

## Internationalization

- Added complete English and Simplified Chinese macOS catalogs. The default is **Follow system**: Chinese system languages use Simplified Chinese and other languages use English. Users can choose an explicit language in the app.
- Switching language updates the panel, menu, window controls, and recognized connection, transfer, and agent messages immediately. The choice persists after relaunch. Android chooses the Macroid Keyboard label from its own locale resources.
- The English UI and settings view were launched and inspected on macOS; switching to Simplified Chinese in Settings updated visible strings immediately.
- Swift package tests: 10 passed, covering language selection and persistence, complete matching catalogs and format placeholders, and translating known diagnostics in both directions while retaining technical details. Android `:app:lintDebug` and `:app:assembleDebug` passed.
- A full Xcode Debug build was used to launch the app. Universal Release build and post-change screenshot capture are part of packaging verification.

## 2026-11-09 Dock icon padding

- The icon uses a fixed 1024×1024 sRGB canvas. The base and mark were proportionally reduced to leave 100 transparent pixels on every side, matching the visible bounds of local Sublime Text and ChatGPT icons while keeping the Macroid mark and colors.
- All ten iconset dimensions were checked to avoid exporting a 2048×2048 source on Retina systems. The Universal build and signature passed, and the bundled ICNS matched the generated icon. Comparison: `artifacts/testing/icon-padding/comparison.png`.
- A runtime check found Launch Services could show a cached icon for the same app path and version. The main view now loads the bundled ICNS directly and sets the same art as the Dock icon on launch. After a normal relaunch, the new icon appeared in the app window. The Universal build and installer checks were repeated.

## 2026-11-09 fusion quality and mirror rotation

- Six Swift tests passed, covering consistent dp layouts across Retina and compatibility pixel/density settings and rejecting invalid dimensions.
- AOSP Android 12 / API 31 and Android 14 / API 34 emulators verified portrait/landscape round trips, 180-degree and reverse-landscape orientation, return to portrait, and simulated-sensor auto-rotation. Each check verified config events before SPS/PPS and the key frame, and touch still reached the test app. Reports: `artifacts/testing/retina-rotation/android31-final-rotation/report.json` and `android34-final-rotation/report.json`.
- Server checks confirmed 840×800 at 320 dpi and 630×600 at 240 dpi both correspond to 420×400 dp, with the same task, display ID, layout, and touch behavior. Earlier checks covered narrow/wide switching, encoder fallback, stale-input rejection, two encoders, and closing during resize. Rotation can run separately with `--rotation-only`.
- The Mac client connected to and decoded Android 12 and 14 streams. It reported the selected quality metadata, changed mirror video and window proportions on rotation, and exposed the auto-rotate control. Normal exit restored the input method and removed a partial upload. Reports: `artifacts/testing/retina-rotation/mac31-final/mac-report.json` and `mac34-final/mac-report.json`. The final Android 14 screenshot was taken after the density-change layout finished.
- Repeatedly replacing a mirror Surface on Android 14 could leave a blank frame when returning to portrait. The implementation now rebuilds the capture display without app tasks. `IRotationWatcher` and a direct `WindowManager` orientation read also cover 180-degree changes for which `DisplayListener` may not fire. Fusion keeps its display and task.
- Rotation, IME, and installation were not retested on a physical device in that pass. Actual image quality still depends on the phone encoder.

## 2026-11-09 build and package validation

- The full Android APK build and `:app:lintDebug` passed. The six Swift tests passed. The rotation listener's non-SDK field is restricted to the uid 2000 shell agent and has a local lint exemption.
- The macOS Release build passed with x86_64 and arm64 in both the app and bundled ADB. APK signature verification passed, and the bundled APK matched the standalone artifact byte-for-byte.
- The Universal ZIP and a read-only mounted DMG passed `codesign --verify --deep --strict`. The DMG passed `hdiutil verify`, contained `Macroid.app` and an Applications shortcut, and was unmounted after checking.
- APK, ZIP, and DMG checksums matched `SHA256SUMS`. The source archive included current source and documentation and excluded build output and local test logs.

## Menu bar entry

On 2026-11-06, the native menu was tested on an Intel Mac. It listed USB devices, connected a OnePlus GM1910 from the device submenu, showed the device name, disabled screen power until a video frame was ready, opened phone mirroring, restored a minimized mirror window, reopened a closed or minimized main panel, and disconnected the phone while closing its mirror window. Device scanning continued with the panel closed. A test copy used a separate bundle ID and was quit after verification.

The native menu appearance and monochrome menu bar icon were checked. Screenshots are `artifacts/testing/menu-bar/connected-menu.png` and `status-bar.png`; the latter includes both the product and a temporary test instance. The Universal x86_64 / arm64 build passed. Android and protocol sources were unchanged during that menu-only pass.

Before version 0.3 packaging, the main panel was closed from Settings and a OnePlus GM1910 was selected from the menu bar's **Connect device** submenu. Macroid reopened the panel on Apps, showed connection progress, and connected. Accessibility evidence: `artifacts/testing/menu-bar/connect-shows-main.txt`. The Universal build, signature, and packaging checks were repeated.

## Version 0.3 fusion windows, screen power, and always-on-top

The real-device tests in this section were authorized by the user. Evidence is under `artifacts/testing/v03/`.

| Environment | Result | Evidence |
| --- | --- | --- |
| OnePlus GM1910, Android 12 / API 31, Qualcomm AVC | Dynamic size, dual encoders, input, physical screen off and restore passed. Independent focus and lock-screen isolation were false; physical screen power was true. | `oneplus12/report.json` |
| Pixel 8 Pro, Android 16 / API 36, Exynos AVC | Same checks passed. Independent focus, lock-screen isolation, and physical screen power were true. | `pixel16/report.json` |
| AOSP Android 12 / API 31, x86_64 emulator | Dynamic size, dual encoders, input, and all 11 baseline protocol checks passed. | `emulator31/report.json`, `smoke31/report.json` |
| AOSP Android 14 / API 34, x86_64 emulator | Same checks passed. | `emulator34/report.json`, `smoke34/report.json` |
| Intel Mac and Pixel Android 16 | Native fusion window, continuous resize, dual-window decode, independent always-on-top, window state restore, IME restore, and incomplete-upload cleanup passed. | `mac-pixel16/mac-report.json` |
| Intel Mac and AOSP Android 14 | Same checks passed. | `mac34/mac-report.json` |
| Intel Mac and OnePlus Android 12 | Window behavior and shared screen-power control passed. An OEM permission denied a later IME change, so the full report's `passed` value is false. | `mac-oneplus12/mac-report.json`, `agent.log` |

Dynamic-resize tests checked the app's display ID, task ID, pixels, density, dp, Insets, and click state. IDs stayed constant through narrow-to-wide-to-narrow changes; app state was retained, system bars were hidden, and Insets were 0. A 3200×1800 request reduced to 1920×1080 and density changed from 240 to 144, leaving about 2133×1200 dp. Other checks covered stale-generation input, invalid dimensions, concurrent windows, and closing during resize.

Both phones continued producing video and accepted input with the physical panel Off. Closing the last window, socket EOF, and killing the Android agent with SIGKILL restored the panel through the independent recovery guard. Checks excluded virtual displays when identifying physical power. A failure to turn off the screen did not commit success or change the phone screen timeout.

API 31 and API 34 also ran encoder-failure injection. If the first reconfiguration allocation failed, the old geometry was restored and video continued on the same display ID. If recovery allocation also failed, the service reported an error and released the display. The injection is a package-private constructor parameter in a separate test dex, not product APK code or a protocol backdoor. API 34 evidence: `resize-failure34.log`; API 31 reported `RESIZE_FAILURE_TEST_PASSED restore=true sameDisplay=true frames=true fatalCleanup=true`.

Mac captures `fusion-narrow.png`, `fusion-wide.png`, and `fusion-narrow-again.png` are in `mac-pixel16/` and `mac-oneplus12/`. They show the native title bar, edge-to-edge content, no phone frame, and the fixture switching between Compact and Wide layouts. Some older `mac34/` captures show an Activity recreation splash; use newer device captures for visual review. This is fixture behavior, not a claim about every third-party app.

The first OnePlus Mac session captured the lock screen and then ADB returned `error: closed`. That interrupted run remains in `mac-oneplus12-interrupted/` and is not counted as passing. After unlocking the phone, window and `screenPowerUI` checks passed. A later legacy regression requested `ime enable`, which the OEM rejected with `android.permission.WRITE_SECURE_SETTINGS`; no phone permission was changed, and the remaining IME/file cleanup steps were not continued on that device. Pixel and both emulators passed the IME checks. OnePlus touch and screen power were independently verified by the device protocol test.

Five Swift tests, Android assemble/lint, and the Universal Mac build passed for this feature set. The Mac runtime test used Intel; arm64 was cross-compiled and architecture-checked. Reduced Motion, frame-by-frame animation timing, every OEM, prolonged use, all manual lock-screen cases, and simultaneous termination of the agent and recovery guard were not tested.

### Reproduction

Start the chosen emulator first; do not let another session use it:

```bash
swift test --package-path macos
./scripts/build-android.sh
./scripts/build-macos.sh
python3 scripts/smoke-android.py --serial emulator-5582 --output artifacts/testing/v03/smoke31
python3 scripts/test-window-features.py --serial emulator-5582 --output artifacts/testing/v03/emulator31
python3 scripts/test-resize-failure.py --serial emulator-5582
artifacts/Macroid.app/Contents/MacOS/Macroid \
  --integration-test emulator-5580 --window-features \
  --integration-output /absolute/path/to/macroid-test-output
```

Physical-device tests require `--allow-device`; physical screen-power tests also need `--screen-power`. The Mac shared-switch test uses `--screen-power-test`. Unlock the phone first; Macroid does not authenticate for the user.

## Version 0.2 device fixes and regression tests

- On GM1910 / API 31 / Qualcomm AVC, the old 886×1920, configured-60-fps Baseline settings reproduced `0x80001001`. Controlled probes showed that forcing Baseline alone caused failure; configurations without it succeeded with or without duplicate-frame parameters. Android 12 did not lack the display-capture API.
- After updating the helper, 886×1920 at configured 60 fps emitted SPS, PPS, key frames, and subsequent frames. The Mac received video through bundled ADB, its own protocol, and CoreMedia. The display layer reached `rendering` and its frame count increased. A static scene does not demonstrate sustained 60 fps.
- The compact native panel, four-column app grid, Devices tab, and phone-shaped mirror window were inspected on an Intel Mac, including transparent corners, complete frames, proportional resizing, and system controls. Close, minimize, and fit-to-screen passed macOS Accessibility checks. Apps and Devices exposed the same prominent **Mirror screen** action with matching accessibility labels.
- All 11 AOSP API 34 Android end-to-end checks passed again, covering own-focus, two windows, input, Unicode, clipboard, files, mirroring, and cleanup.
- The final 0.2 Universal build decoded two windows on Intel Mac with API 34 and passed input-method restore and incomplete-upload cleanup.
- Three Swift protocol tests, Android lint, and Universal build passed. Apple Silicon had cross-build and architecture checks only.
- A real wireless session reused existing ADB pairing. Macroid showed Wi-Fi in Devices, forwarded the selected wireless serial, and maintained a TCP connection to the phone's ADB TLS endpoint. After the user unplugged USB, video continued and ADB confirmed the USB device was gone. This pass validated an existing pairing and did not repeat the six-digit pairing flow.
- Results are under `artifacts/testing/v02/`; version 0.1 reports remain in their original directory.

## Earlier build and baseline checks

- Android `:app:assembleDebug` and `:fixture:assembleDebug` succeeded; `:app:lintDebug` had no errors. Documented local lint suppressions apply only to the hidden-API bridge that runs as shell. Other warnings covered target SDK, shared-storage paths, and backup configuration.
- Three Swift protocol tests covered byte-by-byte frame parsing, coalesced frames, rejected versions and lengths, and Annex B start codes with emulation prevention.
- Xcode Release build passed. `lipo -info` confirmed x86_64 and arm64 for the main executable and bundled ADB. The Mac app passed `codesign --verify --deep --strict`; ad-hoc signing is not Developer ID signing or Apple notarization.
- APK metadata reported `io.macroid.bridge`, minSdk 31, targetSdk 36, and no launchable Activity.

## Android 12 / API 31

An AOSP x86_64 API 31 emulator passed the following checks. Results: `artifacts/testing/android31/report.json`.

1. Macroid authentication, product handshake, and capability negotiation.
2. App enumeration and PNG icon retrieval.
3. A test app running on a non-zero display, with display ID verified by its protected state Provider.
4. Touch injection incrementing a counter in the app.
5. Macroid IME entry of `你好 Macroid 🙂`, followed by a key event deleting characters; the test app verified the changed text.
6. Bidirectional Unicode clipboard transfer.
7. Chunked transfer of a random 420,000-byte file with matching SHA-256; same-name overwrite and reads outside shared storage were rejected.
8. Two apps producing H.264 video on separate secondary displays.
9. Real video frames from main-screen mirroring.
10. On socket disconnect: service exit, default keyboard restore, and virtual-display release.

These checks validate app state and real video, not just successful API responses.

## Mac client

Runtime platform: Intel / x86_64. Through the real `AppModel`, bundled APK installation, ADB forwarding, Network connection, CoreMedia, and `AVSampleBufferDisplayLayer`, two apps reached `rendering`. Report: `artifacts/testing/mac31/mac-report.json`. A cached UI screenshot checked the device sidebar, app layout, and connection state. Raw H.264 was also independently decoded and verified to contain the test app.

The final Mac build decoded two windows on Android 14, loaded 13 app icons, and captured the UI. Through the real client it enabled Macroid IME, created an incomplete upload, and disconnected normally. The original keyboard was restored and the temporary file removed. `artifacts/testing/mac34/mac-report.json` reports `passed`, `restoredIME`, and `removedPartialUpload` as `true`.

Apple Silicon arm64 compiled successfully but was not run on Apple Silicon hardware. Other vendors, network performance, prolonged use, lock screens, and work profiles need more testing.

## Newer Android systems

The Android 16.1 / API 36 emulator image did not finish starting. Macroid was not run there; this is not an app compatibility result.

An AOSP x86_64 Android 14 / API 34 emulator passed the ten Android 12 core checks and also rejected a wrong token and oversized frame by closing the connection. It reported `ownFocus=true`, distinct IDs for two fusion displays, and video output from main-screen capture. Report: `artifacts/testing/android34/report.json`.
