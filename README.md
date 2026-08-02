# VisionDrop

通过屏幕与摄像头之间的单向光学信道传输文件：发送端把文件切片编码成滚动播放的二维码序列，接收端用摄像头连续扫描并重组出原始二进制文件。全程不依赖网络、蓝牙、配对或可移动介质，适用于物理隔离环境。

## 仓库结构

```
VisionDrop/
├── sender/              发送端
│   └── java/            Java Swing 桌面版（现有实现）
├── receiver/            接收端（iOS，SwiftUI + Vision）
└── README.md
```

`sender/web/`（html/js 技术栈）尚未开始，后续新增。

## 两端现状

### 发送端 sender/java

Java 8+ / Maven / ZXing 3.5.1 的 Swing 桌面程序。文件按 1024 字节分片，每片封装成 JSON（含 fileId、fileName、totalChunks、chunkIndex、Base64 数据、CRC32），生成二维码后循环播放。支持暂停、上一片/下一片手动切换、片段列表双击跳转、指定片段筛选、播放间隔调节（100–30000ms）。二维码采用 LRU 缓存加后台预取线程流式生成，避免大文件启动时的长时间等待。

详见 [sender/java/README.md](sender/java/README.md)。

### 接收端 receiver

SwiftUI + Vision 的 iOS 应用。摄像头连续扫描，可调分辨率（720p/1080p）与帧率上限（5–30fps），超出频率的相机回调直接丢弃以控制 ML 推理负载和发热。已落盘的 payload 记入集合，重复帧在 JSON/Base64/CRC32 之前 O(1) 短路。

接收端 README 记录了扫描帧率与发送端显示间隔之间的**采样混叠模型**——每个二维码的期望扫描次数 `N = 显示间隔 × 帧率 / 1000`，经验法则是 `N ≥ 2.5`，且应避开整数比以防相位锁定。这套模型是后续所有参数调整的依据。

详见 [receiver/README.md](receiver/README.md)。

## 改造路线

当前编码层效率偏低：单帧 QR 载荷 1486 字节里只有 1024 字节是有效数据（68.9%），Base64 固定膨胀 4/3，JSON 外壳每帧重复携带文件名等元信息。丢帧只能靠循环重播补齐，尾部收敛慢，需要手工补帧。

计划分三步改造：

1. **二进制帧格式** —— 去掉 JSON 与 Base64，改 16 字节二进制帧头，文件名等元信息移入流内元数据头。已实测验证：ZXing 经 ISO-8859-1 映射可无损写入任意字节（含 0x00/0xFF），接收端通过 `VNBarcodeObservation.payloadData`（iOS 17+）取原始字节。同等识别难度下单帧有效数据 1024 → 1511 字节。
2. **压缩** —— 整文件 raw deflate，压缩后不变小则自动关闭。收益取决于文件类型，文本类 3–7 倍，已压缩格式接近零。
3. **LT 喷泉码** —— 每帧为若干源块的 XOR，种子决定组合，接收端收满约 1.15×K 帧即可还原，彻底消除重传与手工补帧。

## 历史说明

本仓库由两个独立仓库合并而来，两侧历史完整保留，提交日期为原值：

- 发送端源自 `markchoi321/Binary2QrCode`，历史路径已重写至 `sender/java/`
- 接收端源自 `markchoi321/QrBinary`，历史路径已重写至 `receiver/`

合并前的基线见 tag `v0.1.0-baseline`。
