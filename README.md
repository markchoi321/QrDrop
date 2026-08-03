# VisionDrop

通过屏幕与摄像头之间的单向光学信道传输文件：发送端把文件编码成滚动播放的二维码序列，接收端用摄像头连续扫描并重组出原始二进制文件。全程不依赖网络、蓝牙、配对或可移动介质，适用于物理隔离环境。

## 仓库结构

```
VisionDrop/
├── protocol/            协议契约、参考实现与跨语言测试向量
│   ├── CONTRACT.md      两端实现的唯一权威
│   ├── refimpl.py       Python 参考实现（编解码 + 选参 + 档位）
│   ├── crosscheck.py    跨语言校验：真实帧字节 -> 参考解码器 -> 比对哈希
│   └── vectors/         测试向量，两端各自比对
├── sender/              发送端
│   └── java/            Java Swing 桌面版
├── receiver/            接收端（iOS，SwiftUI + Vision）
└── README.md
```

`sender/web/`（html/js 技术栈）尚未开始，后续新增。

## 协议

五层结构，详见 [protocol/CONTRACT.md](protocol/CONTRACT.md)：

| 层 | 职责 |
|---|---|
| L5 会话 | 多会话并发、进度持久化、确定性 sessionId 续传 |
| L4 流 | 元数据头 + 可选 raw deflate + 文件内容 |
| L3 编码 | 喷泉码，按文件大小分档选用解方程（RLNC）或剥洋葱（LT） |
| L2 帧 | 20 字节二进制帧头 + m 个无头编码块 |
| L1 物理 | 单码二维码生成/识别，ECC=L，档位 V15–V40 |

三个要点：

- **无 JSON 无 Base64**。20 字节帧头承载 sessionId / K / T / m / baseBlockId / CRC32，文件名等元信息内嵌进流层，不再每帧重复。单帧有效载荷率从 68.9% 提升到 99.2%（V40）。
- **喷泉码**。发送端持续发出编码块，接收端收够任意数量即可还原，不需要指定重发哪一块——手工补帧与重播轮次的概念都消失了。丢帧代价严格线性：50% 丢帧只是帧数翻倍，不存在长尾。
- **块与帧解耦**。源块大小 T 由文件大小决定并在会话内固定，二维码档位由用户在传输过程中随时调整。换档只改变每帧块数 m，`T`/`K`/`codec`/`sessionId` 均不变，**接收端已收到的编码块继续有效**。

编码块只在帧头携带 `baseBlockId`，参与异或的源块由两端用同一 PRNG 从块序号推导，不占载荷。这要求两端 PRNG 与度分布逐位一致，故有 `protocol/vectors/`。

## 两端现状

### 发送端 sender/java

Java 8+ / Maven / ZXing 3.5.1 的 Swing 桌面程序。三阶段流程：选择文件（自动定档并锁定会话参数）→ 对焦对齐（静止单帧）→ 播放（无限帧流）。播放中可调档位与显示间隔，可全屏播放，均不影响接收端已有进度。播放游标以 sessionId 为键持久化，重启后续推。二维码采用 LRU 缓存加后台预取线程流式生成。

详见 [sender/java/README.md](sender/java/README.md)。

### 接收端 receiver

SwiftUI + Vision 的 iOS 应用。摄像头连续扫描，可调分辨率（720p/1080p）与帧率上限（5–30fps），超出频率的相机回调直接丢弃以控制 ML 推理负载和发热。多会话并行维护，进度以二进制 `.vdpg` 格式自动落盘并在启动时恢复。

两种识别引擎都能取二进制载荷：Vision 与 AVFoundation 都能拿到 `CIQRCodeDescriptor`，其 `errorCorrectedPayload` 是 QR 的原始数据码字（含模式指示符、字符计数与填充），必须按位取出字节模式段才是帧字节，详见 [CONTRACT.md 11.5](protocol/CONTRACT.md)。AVFoundation 在采集管线内完成检测，功耗低于逐帧 Vision 推理，更适合高帧率扫描。接收端保留旧 JSON 格式的解析分支（按载荷首字节区分），新版接收端仍可接收旧版发送端的传输。

扫描帧率上限 60fps。超过 30fps 需显式选择支持高帧率的 `activeFormat`（`sessionPreset` 隐含 30fps 上限）。这直接放宽了发送端的显示间隔下限：按 `N = 间隔 × 帧率 / 1000 ≥ 2.5`，30fps 对应 83ms，60fps 对应 42ms。

接收端 README 记录了扫描帧率与发送端显示间隔之间的**采样混叠模型**——每个二维码的期望扫描次数 `N = 显示间隔 × 帧率 / 1000`，经验法则是 `N ≥ 2.5`，且应避开整数比以防相位锁定。这套模型是所有参数调整的依据。

详见 [receiver/README.md](receiver/README.md)。

## 验证

```bash
python3 protocol/refimpl.py check                      # 参考实现自检
mvn -o -f sender/java/pom.xml test                     # 发送端向量比对
xcodebuild test -project receiver/QrBinary.xcodeproj \
  -scheme QrBinary -destination 'platform=iOS Simulator,name=iPhone 17'
```

两端各自比对 `protocol/vectors/` 下的全部向量（PRNG、量化度分布、邻居集合、系数向量、选参、档位、整帧字节、raw deflate 往返），并各自跑 0/10/30/50% 丢帧的端到端还原与 SHA-256 校验。

跨语言联测：发送端导出帧转储后

```bash
python3 protocol/crosscheck.py <dump> --sha <原始文件sha256>
```

**注意**：Swift 解码器在 Debug 构建下比 Release 慢约 50 倍。真机现场标定务必用 Release 构建，否则大文件的实时消元跟不上扫描速度。

## 待办

- 识别率标定（设计文档 11.1）：档位扫描 + 显示尺寸，决定 720p / 1080p 各自的可用档位上限
- `sender/web/`

## 历史说明

本仓库由两个独立仓库合并而来，两侧历史完整保留，提交日期为原值：

- 发送端源自 `markchoi321/Binary2QrCode`，历史路径已重写至 `sender/java/`
- 接收端源自 `markchoi321/QrBinary`，历史路径已重写至 `receiver/`

合并前的基线见 tag `v0.1.0-baseline`。
