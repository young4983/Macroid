# 验证记录

测试日期：2026-11-05。0.1 的验证限于本项目 Android 模拟器；0.2 增加用户授权的一加 GM1910 / Android 12 真机投屏验证。以下先列 0.2 结果，再保留 0.1 的验证范围。

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
