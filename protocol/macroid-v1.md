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

JSON 为 UTF-8 对象。视频负载前 8 字节为 `presentationTimeUs`（大端 int64），后续为 MediaCodec H.264 Annex B 数据。config 帧包含 SPS/PPS。该版本使用 AVC baseline，以降低解码和帧重排复杂度。

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
| `stream.open` | `stream,mode,package?,width?,height?,density?,fps?,bitrate?` | `stream,display,width,height,density,codec,mode,encoder,fps` |
| `stream.close` | `stream` | 空对象；幂等 |
| `stream.sync` | `stream` | 请求关键帧 |
| `input.pointer` | `stream,action,x,y,scrollX?,scrollY?` | 空对象 |
| `input.key` | `stream,code,meta?` | Android KeyEvent code / meta |
| `input.text` | `stream,text` | 空对象；Unicode 需要启用 IME |
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

视频默认 720×1280 / 240dpi / 60fps / 6Mbps。请求尺寸限制 320–2560。主屏使用真实比例并将最长边限制在 1920。实际宽高按编码器对齐与尺寸能力收缩；硬件失败后尝试 30fps、最长边 1280，再尝试软件编码器（最长边 960/720、24fps）。不强制 AVC profile，B 帧上限为 0。`stream.open` 返回实际 `width`、`height`、`encoder` 和配置 `fps`，应使用这些元数据设置画面和输入坐标。编码器仍可能因并发资源或厂商限制失败。

坐标以编码画面像素计，不含 Mac 的黑边。主屏输入会换算到真实显示尺寸。pointer action 为 Android `0=DOWN,1=UP,2=MOVE,3=CANCEL,8=SCROLL`。文字限 65536 个 Java UTF-16 code units；客户端应显式启用 IME，不应自动更改用户键盘。

文件数据 Base64 编码，每块原始数据最多 196608 字节。服务只访问规范化后的主用户共享存储，拒绝向上穿越和访问应用私有路径。上传在目标目录写临时文件，按连续 offset 验证，在确认完整大小并同步后提交；拒绝覆盖已有文件。断开删除本次未完成的临时上传文件。该版本不支持断点续传。

能力字段应作为 UI 与未来扩展的协商依据，不应只凭 SDK 推断所有设备可用。v1 明确报告 `audio=false`、`virtualCamera=false`。不支持的协议版本应拒绝，而不是尝试解释为官方产品协议。
