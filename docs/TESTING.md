# 验证记录

最新测试日期：2026-11-06。以下先列 0.3 的结果，再保留 0.2 / 0.1 的历史验证范围。

## 菜单栏入口增量验证

2026-11-06，Intel Mac 实际运行并通过原生菜单操作验证：未连接时列出 USB 设备；从设备子菜单连接一加 GM1910 后显示设备名；无视频会话时“关屏使用”禁用，投屏出帧后启用；菜单可打开手机投屏、恢复最小化的投屏窗口、重新打开已关闭或最小化的主面板；设备子菜单可断开连接，投屏窗口随之关闭。主面板关闭期间设备扫描仍由应用生命周期管理。测试副本使用独立 bundle ID，验证后退出。

已检查原生菜单外观和根据应用叠窗标志绘制的单色菜单栏图标。截图位于 `artifacts/testing/menu-bar/connected-menu.png` 和 `status-bar.png`（后者包含产品实例与临时验证实例的两个图标）。Universal x86_64/arm64 构建通过；本次未改动 Android 助手与协议，未重复 Android 全套回归。

0.3 标签打包前补验：先在“设置”页关闭主面板，再从菜单栏“连接设备”选择一加 GM1910，主面板重新显示且选中“应用”页，设备连接成功。连接操作会先打开主面板再开始安装/握手，使进度可见。实际窗口和菜单的 Accessibility 结果保存在 `artifacts/testing/menu-bar/connect-shows-main.txt`。本次安装包重新完成 Universal 构建、签名及打包校验。

## 0.3 融合窗口、关屏使用与置顶

本次真机测试由用户授权。证据位于 `artifacts/testing/v03/`，下面的路径均相对于该目录。

| 环境 | 验证结果 | 证据 |
| --- | --- | --- |
| 一加 GM1910，Android 12 / API 31，Qualcomm AVC | 动态尺寸、双路编码、输入、物理关屏与恢复通过；独立焦点和锁屏隔离能力为 false，物理关屏为 true | `oneplus12/report.json` |
| Pixel 8 Pro，Android 16 / API 36，Exynos AVC | 同上；独立焦点、锁屏隔离、物理关屏分别协商为 true | `pixel16/report.json` |
| AOSP Android 12 / API 31，x86_64 模拟器 | 动态尺寸、双路编码、输入及全部 11 项基础协议回归通过 | `emulator31/report.json`、`smoke31/report.json` |
| AOSP Android 14 / API 34，x86_64 模拟器 | 同上 | `emulator34/report.json`、`smoke34/report.json` |
| Intel Mac + Pixel Android 16 | 原生融合窗口、连续缩放、双窗口解码、独立置顶、关闭重开后的尺寸和置顶恢复通过；输入法与未完成上传清理通过 | `mac-pixel16/mac-report.json` |
| Intel Mac + AOSP Android 14 | 同上 | `mac34/mac-report.json` |
| Intel Mac + 一加 Android 12 | 本次窗口功能及共享关屏开关均通过；后续输入法切换被 OEM 权限拒绝，因此整套报告的 `passed` 为 false | `mac-oneplus12/mac-report.json`、`mac-oneplus12/agent.log` |

动态尺寸测试验证真实应用报告的 display ID、task ID、像素、density、dp、Insets 和点击状态。窄→宽→窄过程中 display/task ID 不变，应用状态保留，状态栏和导航栏不可见且 Insets 为 0。3200×1800 的请求降至 1920×1080 时 density 从 240 同步变为 144，应用仍收到约 2133×1200dp。测试还覆盖旧 generation 输入拒绝、非法尺寸拒绝、多窗口同时编码，以及调整尚未完成时关闭窗口。

两台真机均验证融合和镜像在物理面板 `Off` 时继续输出视频，点击改变 fixture 状态；关闭最后一个窗口、socket EOF 和实际 `SIGKILL` Android agent 后，独立守护均将面板恢复为 `On`。判定物理面板时排除虚拟显示；没有用 Android 的逻辑交互状态代替面板电源状态。关屏失败不会提交已开启状态，不会修改用户的息屏超时设置。

API 31 和 API 34 另外执行真实编码器故障注入：第一次重配置分配失败时恢复旧几何并继续出帧，display ID 保持不变；连恢复分配也失败时发送错误并释放副屏。注入入口仅为包内构造参数，测试 dex 独立加载，不进入产品 APK，也没有协议后门。API 34 输出保存在 `resize-failure34.log`，API 31 同样输出 `RESIZE_FAILURE_TEST_PASSED restore=true sameDisplay=true frames=true fatalCleanup=true`。

Mac 的 `fusion-narrow.png`、`fusion-wide.png`、`fusion-narrow-again.png` 保存在 `mac-pixel16/` 和 `mac-oneplus12/`。已检查完整原生标题栏、贴边内容、无手机外壳，以及 fixture 从 Compact layout 切换到 Wide layout 后再切回。旧 `mac34/` 截图可能捕获 Activity 重建中的启动画面，视觉验收以较新的真机截图为准。布局切换由 fixture 自己响应 Android 配置完成，不代表所有第三方应用都提供平板布局。

一加首轮 Mac 联调捕获到 Android 锁屏页，随后 ADB 查询返回 `error: closed`；该中断结果保留在 `mac-oneplus12-interrupted/`，未计为通过。设备解锁后的复测已通过本次全部窗口检查及 `screenPowerUI` 检查。后续旧功能回归执行 `ime enable` 时，系统明确拒绝 shell 的 `android.permission.WRITE_SECURE_SETTINGS`，所以未继续该设备上的输入法/文件清理环节，也未改变手机权限设置。Pixel 和两台模拟器的输入法相关回归均通过。一加的触控输入与关屏操作由独立真机协议测试确认通过。

Swift 5 项单元测试通过，覆盖拆包/合包、协议拒绝、配置与视频边界顺序、pt/dp 几何及 Annex B。Android assemble/lint 和 Universal macOS 构建通过。Mac 运行测试使用 Intel；arm64 仅完成交叉编译和架构检查。减少动态效果遵循系统设置，但未单独完成该设置下的视觉验收；动画时长未用逐帧测量。未覆盖所有 OEM、长时间运行、所有手动锁屏情形，以及 agent 与守护同时被杀或系统整体关闭时的恢复。

### 复现命令

先构建并启动指定模拟器；不要让另一个会话占用同一设备：

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

真机必须显式传入 `--allow-device`；物理关屏测试另加 `--screen-power`，Mac 共享开关测试用 `--screen-power-test`。测试前在手机上解锁，Macroid 不代替用户认证。示例：

```bash
python3 scripts/test-window-features.py --serial DEVICE_SERIAL --allow-device --screen-power \
  --output artifacts/testing/v03/device
artifacts/Macroid.app/Contents/MacOS/Macroid \
  --integration-test DEVICE_SERIAL --allow-device --window-features --screen-power-test \
  --integration-output /absolute/path/to/macroid-device-output
```

## 0.2 实机修复与回归

- GM1910 / API 31 / Qualcomm AVC：旧配置 886×1920、60fps、Baseline 在 configure 阶段复现 `0x80001001`。四组控制变量探针确认：只加 Baseline 就失败；不加 Baseline 的配置无论是否指定重复帧参数均成功。并非 Android 12 缺少投屏接口。
- 更新助手后，886×1920 / 配置 60fps 成功输出 SPS、PPS、关键帧和后续帧。Mac 真正通过内置 ADB、自己的协议和 CoreMedia 接收视频，显示层为 `rendering`，连续检查帧数增加。静态画面下并不等同于实际输出 60fps。
- 新原生窄面板、四列应用、设备页和 iOS 模拟器风格手机窗口已在 Intel Mac 实际启动并检查透明圆角、完整画面、比例缩放与系统按钮。关闭、最小化、适合屏幕均通过 macOS Accessibility action 检查；调整后三颗按钮按紧凑 macOS 标准尺寸呈现。主窗口使用 macOS 原生标题栏控制；应用页与设备页均使用相同的“屏幕镜像”高亮按钮，应用页 AX 标签与可见按钮文本一致。
- AOSP API 34 全部 11 项 Android 端到端检查再次通过，涵盖 ownFocus、双窗口、输入、Unicode、剪贴板、文件、镜像和清理。
- 最终 0.2 Universal 构建在 Intel Mac + API 34 上再次通过两路显示层解码、输入法恢复和未完成上传清理。
- Swift 三项协议测试、Android lint 和 Universal 构建通过。Apple Silicon 仍只有交叉编译与架构检查，未在对应硬件运行。
- 真机无线：开启系统无线调试后，复用已有 ADB 配对。通过 Macroid 的 Wi-Fi 连接界面连接，设备页显示 Wi-Fi；转发绑定网络 serial，Mac ADB 到手机 TLS 端口存在真实 TCP 连接。手机拔掉 USB 后，用户确认画面继续更新；ADB 列表也确认 USB 设备消失。首次六位码配对分支尚未在本次重新配对测试；本次验证的是已有配对连接、无线助手启动、视频传输和拔线继续播放。
- 结果位于 `artifacts/testing/v02/`；0.1 报告仍保留在原目录，用于区分版本。

## 构建与基础检查

- Android `:app:assembleDebug`、`:fixture:assembleDebug` 成功。
- Android `:app:lintDebug` 通过，没有错误。对仅在 shell 执行的系统桥使用有说明的局部隐藏 API 检查抑制；剩余提示包括目标 SDK、共享存储路径和备份配置。
- Swift 协议单元测试 3 项通过，覆盖逐字节拆包与合包、协议版本与长度拒绝、Annex B 混合起始码和 emulation prevention。
- Xcode Release 构建成功；`lipo -info` 确认主可执行文件和内置 ADB 均有 `x86_64 arm64`。
- Mac 应用 `codesign --verify --deep --strict` 通过。本地 ad-hoc 签名不代表 Developer ID 签名或 Apple 公证。
- APK 元数据确认包名 `io.macroid.bridge`、minSdk 31、targetSdk 36，没有 launchable Activity。

## Android 12 / API 31

环境：新建 AOSP x86_64 API 31 模拟器。所有以下检查通过，结果保存在 `artifacts/testing/android31/report.json`：

1. 独立 Macroid 协议认证、产品与能力协商。
2. 启动应用枚举和 PNG 图标。
3. 测试应用在非 0 display 上运行，由测试应用的受保护状态 Provider 验证 display ID。
4. 触控注入点击按钮，应用内部点击计数实际增加。
5. Macroid IME 输入 `你好 Macroid 🙂`，再通过目标键盘事件删除字符；测试应用状态验证文本变化。
6. 双向 Unicode 剪贴板。
7. 420000 字节随机二进制文件分块上传、下载，SHA-256 一致；拒绝同名覆盖和共享存储边界外读取。
8. 两个不同应用在两个不同副屏同时输出 H.264 视频。
9. 主屏投屏实际输出视频帧。
10. 主动断开 socket 后服务退出、默认输入法恢复、虚拟显示释放。

这里验证的是应用状态和真实视频流，而不是只断言 API 调用返回成功。

## Mac 客户端

运行平台：Intel / x86_64。通过真实 AppModel、内置 APK 安装、ADB 转发、Network 连接、CoreMedia 和 AVSampleBufferDisplayLayer 测试，两个不同应用的显示层均进入 `rendering` 状态。

结果：`artifacts/testing/mac31/mac-report.json`。应用 UI 已通过真实窗口缓存截图检查，验证设备侧栏、应用布局和连接状态。原始 H.264 视频也独立解码检查到测试应用内容。

最终 Mac 构建另外连接 Android 14 完成双窗口解码；所有 13 个应用图标加载后保存界面截图。测试还通过真实客户端启用 Macroid IME、创建未完成上传，再正常断开，验证原输入法恢复且临时文件删除。结果在 `artifacts/testing/mac34/mac-report.json`，其中 `passed`、`restoredIME`、`removedPartialUpload` 均为 `true`。

Apple Silicon arm64 已构建，尚未在 Apple Silicon 硬件上执行。0.1 当时未测试 OEM 真机；0.2 现已增加 GM1910 投屏验证。其他厂商、网络性能、长时间运行、锁屏和工作资料仍需要扩大测试。

## 新系统验证

Android 16.1 / API 36 的已安装模拟器镜像未正常完成启动，问题发生在系统镜像启动阶段，未运行 Macroid 测试。因此该环境不能作为通过或失败的应用兼容性结论。

Android 14 / API 34：使用另外新建的 AOSP x86_64 模拟器。上述 Android 12 的十项核心链路检查全部通过，另验证错误令牌与超大帧会关闭连接。设备实际报告 `ownFocus=true`；两个融合显示 ID 不同，主屏捕获输出视频帧。结果在 `artifacts/testing/android34/report.json`。
