# Macroid Wire v1

该协议由 Macroid 自行定义，与 AndroMeld 的 WebSocket / media 协议及 scrcpy 的 socket 格式不兼容。

## 传输与生命周期

Mac 通过 ADB 安装 `io.macroid.bridge`，取得 APK 路径后，以 shell uid 2000 执行：

```text
CLASSPATH=<installed APK> app_process / io.macroid.bridge.AgentMain <socket-name> <token>
```

服务监听 Android abstract Unix socket `macroid_<random>`。Mac 使用 `adb -s <serial> forward tcp:0 localabstract:<socket-name>`，仅连接本机分配端口。令牌每次启动生成，不写入持久配置。Android 服务不监听 LAN TCP 端口。无线模式经已配对的 Android 无线调试 TLS 连接转发同一协议；客户端提供 `adb pair` / `adb connect` 配对入口，不自动启用经典 TCP 5555。当前单一会话不支持 USB/Wi-Fi 自动迁移。

第一帧必须在 10 秒内提交 `hello` 和令牌；令牌比较使用常量时间比较。服务只接受一次连接；未连接服务 60 秒后退出。关闭 socket 会清理所有视频会话、未完成上传并恢复通过本会话切换的输入法。

ADB 配对与授权承担设备身份和传输安全。Wire 层只提供会话认证，不额外实现 TLS；不得将本地转发端口公开给网络。

## 帧格式

所有整数为无符号大端。固定头长 16 字节。

| 偏移 | 长度 | 含义 |
|---|---|---|
| 0 | 4 | ASCII `MCRD` / `0x4d435244` |
| 4 | 1 | 版本，固定 `1` |
| 5 | 1 | 类型：`1` JSON，`2` 视频 |
| 6 | 2 | 标志；JSON 为 0，视频 bit 0 为 codec config，bit 1 为关键帧 |
| 8 | 4 | 视频 stream ID；JSON 为 0 |
| 12 | 4 | 负载字节数，不超过 16 MiB |
| 16 | N | 负载 |

接收方必须处理头和负载任意拆包、多个帧合包；在分配完整负载前校验长度与版本。

JSON 为 UTF-8 对象。视频负载前 8 字节为 `presentationTimeUs`（大端 int64），后续为 MediaCodec H.264 Annex B 数据。config 帧包含 SPS/PPS。编码器自行选择支持的 AVC profile；不强制 Baseline，B 帧上限为 0。

## 请求与响应

请求包含递增整数 `id` 和 `op`，其他字段放在同一对象。`id=0` 表示无需成功响应，适合高频输入。

```json
{"id":1,"op":"hello","token":"<per-session token>"}
```

```json
{"id":1,"ok":true,"result":{"product":"Macroid","protocol":1,"sdk":31,"capabilities":{"ownFocus":false}}}
```

```json
{"id":2,"ok":false,"error":"human-readable reason"}
```

错误不应杀死已认证连接，除非无法继续解析帧。异步事件包含 `event`，例如：

```json
{"event":"stream.error","stream":1,"message":"encoder failure"}
```

## 操作

| op | 参数 | 结果 |
|---|---|---|
| `hello` | `token` | 产品、版本、SDK、设备与能力；只允许作为首帧 |
| `ping` | 无 | `time` |
| `device.info` | 无 | 同 hello 设备信息 |
| `apps.launch` | `package` | 在 display 0 启动应用，用于关闭融合模式后的主屏操作 |
| `apps.list` | 无 | `apps: [{package,name}]`，仅可启动应用 |
| `apps.icon` | `package` | `png`，Base64 编码 PNG |
| `stream.open` | `stream,mode,package?,width?,height?,density?,fps?,bitrate?,maxSize?,configEvents?` | `stream,display,width,height,density,codec,mode,encoder,fps,generation` |
| `stream.resize` | `stream,width,height,density` | 同 stream.open；恢复旧尺寸时包含 `restored,warning` |
| `stream.rotate` | `stream,automatic?` | 镜像流：默认切换横竖屏（90°）；`automatic=true` 开启手机自动旋转。返回 `rotation,rotationLocked,requestedRotation` |
| `device.screenPower` | `screenOff`（boolean） | `screenOff`；设备级、非持久状态 |
| `stream.close` | `stream` | 空对象；幂等 |
| `stream.sync` | `stream` | 请求关键帧 |
| `input.pointer` | `stream,generation?,action,x,y,scrollX?,scrollY?` | 空对象 |
| `input.key` | `stream,generation?,code,meta?` | Android KeyEvent code / meta |
| `input.text` | `stream,generation?,text` | 空对象；Unicode 需要启用 IME |
| `ime.enable` / `ime.disable` | 无 | `enabled` |
| `clipboard.set` | `text` | 空对象 |
| `clipboard.get` | 无 | `text` |
| `files.list` | `path` | 规范路径和 `entries` |
| `files.read` | `path,offset,count?` | `data,size,offset` |
| `files.upload.begin` | `path,size` | `transfer` |
| `files.upload.chunk` | `transfer,offset,data` | 下一 `offset` |
| `files.upload.finish` | `transfer` | 空对象 |
| `files.upload.cancel` | `transfer` | 空对象 |

`stream` 由客户端选择，范围 1–65535，最多四个并发会话。`mode=fusion` 创建 own-content 副屏并启动 `package`；`mode=mirror` 捕获 display 0，忽略应用参数。成功元数据先于首个视频帧发送。

视频协议默认 720×1280 / 240dpi / 60fps / 6Mbps。融合请求尺寸限制 320–8192、请求 density 为 40–640；编码能力仍会降低最终像素尺寸。`maxSize` 为编码最长边上限（720–4096，默认 1920）；当前 Mac 客户端融合请求 4096 上限、12Mbps，并按显示器 backing scale 同比设置像素和 density，Retina 默认 2 倍 / 320dpi，兼容模式为 1.5 倍 / 240dpi。两种模式保持相同 dp 布局。主屏仍使用真实比例并将最长边限制在 1920。实际宽高按编码器对齐与尺寸能力收缩；硬件失败后尝试 30fps、最长边 1920/1280，再尝试软件编码器（最长边 960/720、24fps）。不强制 AVC profile，B 帧上限为 0。`stream.open` 返回实际 `width`、`height`、`encoder` 和配置 `fps`，应使用这些元数据设置画面和输入坐标。编码器仍可能因并发资源或厂商限制失败。

坐标以编码画面像素计，不含 Mac 的黑边。主屏输入会换算到真实显示尺寸。pointer action 为 Android `0=DOWN,1=UP,2=MOVE,3=CANCEL,8=SCROLL`。文字限 65536 个 Java UTF-16 code units；客户端应显式启用 IME，不应自动更改用户键盘。

文件数据 Base64 编码，每块原始数据最多 196608 字节。服务只访问规范化后的主用户共享存储，拒绝向上穿越和访问应用私有路径。上传在目标目录写临时文件，按连续 offset 验证，在确认完整大小并同步后提交；拒绝覆盖已有文件。断开删除本次未完成的临时上传文件。该版本不支持断点续传。

能力字段应作为 UI 与未来扩展的协商依据，不应只凭 SDK 推断所有设备可用。v1 明确报告 `audio=false`、`virtualCamera=false`。不支持的协议版本应拒绝，而不是尝试解释为官方产品协议。

## 0.3 可选能力：动态尺寸与关屏

`hello.capabilities` 增加 `resize`、`streamConfig`、`screenPower`、`screenPowerReason` 和 `alwaysUnlocked`；`ownFocus` 独立保留。缺失字段按 false 处理。`agentPid` 是用于进程生命周期诊断的 Android agent PID。帧头和视频负载不变，旧客户端不请求新能力时继续使用固定尺寸。

动态尺寸流必须在打开时指定 `configEvents=true`。每次开始编码（包括首次打开、成功 resize 或失败后恢复）都先发送以下事件，再发送该代 SPS/PPS 和首个关键帧：

```json
{"event":"stream.config","stream":1,"display":7,"generation":2,"width":1440,"height":960,"density":240,"codec":"h264","encoder":"...","fps":60,"mode":"fusion"}
```

服务端停止并等待上一代编码线程退出后才发出此事件；`generation` 在同一次打开期间递增。事件与视频须在客户端同一有序通道消费，先更新几何和解码状态；响应 continuation 的调度顺序不能当作视频分界。resize 响应可能晚于新配置事件或新视频。发送输入时可携带 generation，过期输入会被拒绝。调整前取消触控，首个新画面就绪后恢复输入。

融合显示保留 display ID，只调整 VirtualDisplay 并更换编码 Surface。降分辨率时同比调整 density，保持请求的 dp 尺寸（取整允许小幅偏差）；不要按编码像素直接判断手机/平板。调整失败会尝试恢复旧尺寸并发送新配置；恢复成功的响应带 `restored=true` 与 `warning`，恢复失败发送 `stream.error`。非法尺寸在停止编码前拒绝。镜像和未请求配置事件的流不支持 resize。

`device.screenPower` 的 `screenOff=true` 关闭物理面板，不关闭虚拟显示或代替用户解锁。须有已产生画面的有效流，手机须处于交互且已解锁状态。API 探测成功并不保证所有 OEM 接受实际操作；失败返回错误，不更改成功状态。状态变化广播 `{"event":"device.screenPower","screenOff":true}`，所有窗口应同步展示。最后一个流关闭/失败、连接断开、正常退出会恢复面板；独立守护通过父进程管道 EOF 处理 agent 异常退出。唤醒锁仅存在于关屏会话中，不修改系统永久息屏设置。物理关屏、独立焦点、锁屏隔离不能相互推断。

## 可选能力：旋转

`hello.capabilities.rotation=true` 表示支持镜像方向追踪和 `stream.rotate`。方向变化的镜像流需要 `configEvents=true`；监听手机主显示的方向、尺寸、density，停止旧编码器后重建视频 Surface，并发送新的 `stream.config`，再发送 SPS/PPS 与关键帧。元数据附带 `rotation`（0–3，90°步进）和 `rotationLocked`。Android 12/13 更新 SurfaceControl 投影，Android 14+ 重建不含应用任务的镜像 VirtualDisplay，避免重复换 Surface 后继续使用失效缓冲；输入始终指向 display 0。镜像本身不接受 `stream.resize`。

`stream.rotate` 默认切换当前方向对应的横竖屏（`rotation XOR 1`，避免手机不支持倒置竖屏时无响应），保留手机原有的自动旋转开关状态；`automatic=true` 显式开启手机自动旋转，此时 `requestedRotation=-1`。系统或应用可能限制方向，客户端以实际配置和新画面为准。方向状态还广播 `{"event":"device.rotation","rotation":1,"rotationLocked":false}`；此事件不是视频配置分界。控制与显示变化重配置串行执行，迟到的 generation 输入继续被拒绝。融合应用的方向由窗口比例与应用布局决定。
