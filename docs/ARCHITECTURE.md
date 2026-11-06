# 架构与 Android 兼容策略

## 两个产品工程

Mac 应用 `io.macroid.desktop` 使用 SwiftUI 构建设备、应用、文件和设置页面；视频窗口以 AppKit 承载 AVSampleBufferDisplayLayer。客户端把 H.264 Annex B 拆成 NAL 单元，使用 SPS/PPS 建立 CoreMedia 视频格式，将访问单元改为长度前缀格式后交给系统解码。没有依赖 FFmpeg、SDL、官方客户端或官方服务端。

菜单栏使用 SwiftUI `MenuBarExtra` 的原生菜单样式，单色 template 图标沿用应用的叠窗造型。主面板是带固定 ID 的单例 `Window`；菜单选择设备后立即打开“应用”页，再通过共享的 AppModel 连接，进度、成功列表和失败提示均在主面板显示。设备扫描归应用生命周期管理，关闭主面板不会停止扫描或断开连接；退出应用仍走统一清理路径。菜单与主面板共用设备、关屏和窗口状态，已有窗口可从菜单恢复最小化并置前。

Android 助手 `io.macroid.bridge` 包含两个执行域：

1. 普通 APK 进程仅提供 Macroid 输入法和受系统 DUMP 权限保护的显式广播接收器。没有 launcher Activity。
2. Mac 通过 ADB 的 `app_process` 以 shell 身份执行 APK 中的 AgentMain。它创建显示、启动应用、注入输入、编码并传送画面，访问 shell 可访问的共享存储。

普通 APK 不会因为声明权限就获得任意显示捕获或输入注入能力。这里的授权来自手机对该 Mac 的 ADB 授权。没有请求 root，也没有在普通应用进程中规避 Android 权限模型。

## 融合与镜像

融合窗口拥有独立 VirtualDisplay、MediaCodec Surface、stream ID 和输入 display ID。应用在手机原有 Android 用户中运行，复用已有安装和数据；这不是 Android 模拟器或账号隔离容器。创建新显示后用 `am start --display` 启动应用。

镜像窗口捕获主显示，输入则注入 display 0。Mac 同时读取和发送同一条经过认证的 ADB 转发连接；控制 JSON 和视频帧有明确帧头，多个视频会话通过 stream ID 复用。

每个编码器拥有独立输出线程；对同一 socket 的写入按整帧串行。Mac 传输和请求状态限制在单一串行队列，UI 和视频显示层在 MainActor。该版本没有复杂的拥塞控制；USB 和稳定的已配对 ADB 网络连接为主要使用场景。

## 编码协商与诊断

0.2 不再固定 AVC Baseline；该参数在一加 GM1910 的 Qualcomm/Oplus 编码器上会触发 configure 错误 `0x80001001`。按 Surface 输入、VideoCapabilities、尺寸对齐、帧率和码率范围选择编码器与参数，硬件优先，失败依次降低负载，再尝试低分辨率软件编码。各次失败释放独立 codec 和 Surface。输出格式变更中的 SPS/PPS 也会发送，避免只依赖厂商的 codec-config buffer。

实际协商结果随 stream.open 返回。Mac 保存本次 agent 的有限长度诊断到 `~/Library/Application Support/Macroid/Logs/agent.log`，不记录会话认证令牌或无线配对码。服务端 12 秒未产生首个画面会报告错误；窗口可重新尝试。

## 无线连接

设备页可输入配对地址、六位配对码和连接地址，调用 Android 官方 ADB TLS 配对。配对码不持久化；仅记住成功连接的地址。无线设备启动相同助手与认证协议，画面经 ADB TLS 传输。USB 会话不会因发现无线设备自动迁移；拔线前应选择无线设备重新连接。

## 版本分支

| 系统 | 融合显示 | 主屏捕获 |
|---|---|---|
| Android 12 / API 31–32 | 旧版 createVirtualDisplay，own-content/public，不请求 shell 无法获得的 trusted 标志 | SurfaceControl 创建显示与投影 |
| Android 13 / API 33 | 旧版创建接口，按实际权限增加 trusted/display group/always unlocked 标志 | SurfaceControl |
| Android 14+ / API 34+ | VirtualDisplayConfig 公开接口，有可信显示权限时增加 own-focus | DisplayManager 隐藏镜像显示接口 |

输入注入按系统存在的 InputManagerGlobal 或 InputManager 选择反射入口。所有隐藏系统接口集中在 ShellPlatform 中，并仅在 shell 进程调用。Lint 中针对该类的 PrivateApi/BlockedPrivateApi/WrongConstant 抑制有意针对 shell 系统桥，不适用于普通 APK 进程；仍需要维护各 Android / OEM 版本的兼容性。

Android 12 实测表明，shell 创建 trusted 显示会被 ADD_TRUSTED_DISPLAY 权限拦截。因此兼容分支需要使用普通副屏，本次集成验证了该路径可启动另一个应用并接受目标输入。独立焦点和锁屏完全隔离没有由此自动成立。较新系统也会在请求可信显示及始终解锁标志前检查实际权限；设备缺少相应授权时保留基础副屏配置，并在能力协商中返回实际可用的 ownFocus。

## Unicode、剪贴板与文件

Mac 视频视图实现 NSTextInputClient，让 macOS 输入法在本地组合候选文本。用户确认启用 Macroid 键盘后，shell 保存原默认输入法并切换到助手 IME，收到提交文字时通过受保护广播让 InputConnection.commitText 写入文本。正常断开时只在仍使用 Macroid 键盘的情况下恢复原键盘，避免覆盖用户期间主动选择的输入法。

不启用 Macroid 键盘时，ASCII 字符通过 KeyCharacterMap 生成并注入目标 KeyEvent。特殊键和编辑快捷键直接发送 Android key code。Android 12/13 的 IME 焦点属于兼容限制，不能声称任意多窗口都有完全独立输入法实例。

剪贴板是显式、手动的文本传输。Android 写入通过 APK 的受保护广播执行，读取使用归属 com.android.shell 的 ClipboardManager；不使用归属 android 包的 system-context 缓存服务，以免造成 uid/package 不一致。

共享存储路径先 canonicalize 再校验边界。文件上传有独立传输 ID、连续偏移验证、临时文件与最终提交；取消和断开删除未完成文件。协议不提供任意 shell 命令执行或应用私有数据访问接口。

## 后续工程方向

按需扩展旋转追踪、音频、通知、拖放和虚拟设备能力。虚拟摄像头/麦克风应独立协商，不能将 Android 16 的虚拟设备能力错误地视为 Android 12 基础融合的必需条件。正式产品发布还需要真机 OEM 矩阵、Apple Silicon 运行验证、发布证书、故障恢复与网络性能测试。

## 0.3 窗口、重配置与电源

融合采用带原生标题栏的 AppKit 窗口，内容区自由改变比例；手机镜像继续使用等比手机外壳。窗口位置/尺寸按应用保存，置顶通过 floating 层级逐窗口持久化，不设置跨所有 Spaces。融合默认内容 420×720 pt，约 1pt=1dp；Mac 的 Retina backing scale 不参与 Android 布局尺寸计算。

窗口尺寸最多每 200ms 提交一次，每流最多一个请求在途并合并为最新目标。编码代次与 VirtualDisplay 生命周期分离，停止旧编码器不会销毁应用任务。新 Surface 绑定同一显示，VirtualDisplay.resize 触发应用正常的 Configuration 更新/Activity 重建；Macroid 不强制 tablet 标志。编码能力降级时同比缩小 density，保留 dp。失败尝试重建上一组有效尺寸。

Transport 将配置事件和视频按 socket 顺序投递到同一 main queue。VideoRenderer 在重配置时保留旧显示层，等待新层首帧可显示后淡入 180ms；减少动态效果时立即替换。macOS 14.4+ 使用 isReadyForDisplay，旧系统使用 rendering 状态。新画面就绪前禁用输入，并通过 generation 拒绝迟到的旧坐标。

关屏使用由设备级 ScreenPower 管理；与 ownFocus/alwaysUnlocked 分开协商。ShellPlatform 封装物理显示 token 与 SurfaceControl 电源接口，Android 14+ 必要时经 system-server 类加载器加载 DisplayControl 与 android_servers JNI 库。独立 app_process 守护持有临时唤醒锁并控制面板；父进程的 stdin 管道关闭时恢复面板和释放锁，包括父进程 SIGKILL。守护自身被强杀且主 agent 仍存活时，主进程监测并恢复；系统整体重启或所有相关进程同时被强杀不属于此清理保证。
