# QrDrop 发送端（Java）

把文件编码成无限的二维码帧流播放出去，接收端用相机扫。协议语义以
`protocol/CONTRACT.md` 为唯一权威，`protocol/refimpl.py` 是参考实现，
两端必须逐位复现 `protocol/vectors/` 下的测试向量。

## 运行

```bash
mvn -o clean package
java -cp target/classes:<zxing jar> org.file.qrcode.QRCodeGeneratorGUI 文件1 [文件2 ...]
```

不带参数启动会弹出文件选择框（支持多选）。每个文件是一个独立会话。

## 三阶段流程

1. **选择文件**：立即按选参算法算出并展示会话参数（T / K / 编码方案 / ε / sessionId），只读
2. **对焦对齐**：静止显示单帧，档位锁在档 1、间隔置灰，用于在接收端完成取景与对焦
3. **播放**：无限帧流。档位与间隔可随时调整，且不重置任何东西

## 三个旋钮

| 旋钮 | 范围 | 说明 |
|---|---|---|
| 档位 | 会话动态生成，最多 10 档 | 左右箭头逐档调整，不提供跳档。换档只改 `m`，`T/K/codec/sessionId` 不变，接收端已收块继续有效 |
| 间隔 | 10–1000 ms | 推荐 75–100 ms；低于 75 只给警告不拒绝。10–50 ms 远低于接收端采样能力，仅供实验 |
| 全屏 | — | 纯白背景、无边框、无动画，二维码按模块整数倍像素渲染 |

会话参数（块大小 T、总块数 K、编码方案、开销 ε、sessionId）由文件大小自动决定，
**会话内不可更改**，界面上是纯展示区，不含任何可交互控件。

## 进度语义

统计区显示的是**发送端已播 / 理论所需**，不是接收端的接收进度——单向信道下发送端无从
得知后者。主指标以**编码块**计而不以帧计：换档会改变每帧块数 `m`，以帧计的百分比会跳变。

播放游标 `nextBlockId` 只在帧真正显示后推进（预取生成的帧不推进），以 `sessionId` 为键
持久化在 `~/.qrdrop/playback/<sessionId>.state`，重启后同一文件推导出同一 sessionId，
游标从上次位置续推。

## 代码结构

```
src/main/java/org/file/qrcode/
├── QRCodeGeneratorGUI.java       界面 + LRU 图标缓存 + 后台预取线程
├── PlaybackState.java            播放游标 / 档位 / 间隔，及其持久化
└── protocol/                     协议实现，逐函数对照 refimpl.py
    ├── Prng.java                 mix32 / xorshift32
    ├── RobustSoliton.java        量化对数 lnq + uint32 CDF + 抽度数
    ├── BlockComposer.java        blockId -> 参与异或的源块索引
    ├── LinearSolveComposer.java  解方程方案（RLNC）系数向量
    ├── PeelingComposer.java      剥洋葱方案（LT）邻居集合
    ├── ParamPicker.java          选参算法
    ├── QrCapacity.java           QR 容量表 + 档位生成
    ├── StreamCodec.java          L4 流层，raw deflate 自适应压缩
    ├── SessionId.java            会话标识确定性推导
    ├── SendSession.java          会话不可变参数 + 源块划分
    └── FrameEncoder.java         整帧字节产出
```

## 测试

```bash
mvn -o test
```

`ProtocolVectorTest` 逐条比对 `protocol/vectors/` 下的全部向量文件。
离线环境下 surefire 的 junit4 provider 若无法解析，可直接运行等价入口：

```bash
java -cp target/classes:target/test-classes org.file.qrcode.protocol.VectorCheck
```

## 使用建议

- 屏幕亮度调至最高，关闭夜览 / 自动色温
- 先在对焦阶段确认能稳定识别，再进入播放
- 从档 1 逐档往上试，识别率悬崖的位置因设备、距离、光照而异
- 播满一轮不代表接收端收全；识别率 90% 时播满一轮只能让接收端收到约九成
