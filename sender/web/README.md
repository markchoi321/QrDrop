# VisionDrop Web 发送端

纯原生 HTML + JS 实现的发送端，零依赖、零构建，双击 `index.html` 即可运行
（或任意静态服务器托管）。协议语义与 `protocol/CONTRACT.md` 逐位一致。

## 文件

| 文件 | 内容 |
|---|---|
| `index.html` | 页面与播放控制（选文件、档位、间隔、游标持久化、帧转储导出） |
| `vd-protocol.js` | 协议层：PRNG / SHA-256 / CRC32 / 量化 CDF / LT 与 RLNC 邻居 / 选参 / 档位 / 流层 / 会话 / 帧编码 |
| `vd-qr.js` | QR 编码器：字节模式、ECC=L、V1–40、八种掩码评估（可固定掩码提速） |
| `test/run-vectors.js` | Node 向量测试：全量比对 `protocol/vectors/`，并导出帧转储 |

## 浏览器兼容性

只用 ES5 语法，不用 Promise / fetch / crypto.subtle / TextEncoder / BigInt /
箭头函数 / let。硬性下限由两个能力决定：

- `Uint8Array`（IE10+ / Android 4.0+ / Safari 5.1+）
- `FileReader.readAsArrayBuffer`（同上）

即 IE10、Android 4 原生浏览器、iOS 6 Safari 及之后的所有浏览器均可运行。
更旧的浏览器会得到明确的能力提示而不是白屏。`Math.imul` 缺失时自动降级为
手工半字乘法。文件导出在 IE10/11 走 `msSaveBlob`，其余走 Blob URL。

## 与桌面（Java）发送端的差异

- **不做压缩**：老浏览器没有原生 deflate 接口，流层 flags bit0 恒为 0。
  契约允许（压缩本就是自适应可选项），接收端按 flag 处理，无需区分来源。
  代价是文本类文件传输帧数变多；jpg/png/zip/mp4 等本就不可压缩，无差别。
- **播放状态存 localStorage**（键 `vdweb.<sessionId hex>`），语义对齐
  `PlaybackState`：游标只在帧真正显示后推进，同一文件同参数重传自动续接。
- **固定掩码选项**：跳过八种掩码评估（任一合法掩码解码端均可读），
  供低端设备在小间隔下提速；默认仍为全评估取最优。

## 验证

```bash
# 全量向量比对 + 导出帧转储（372 项检查）
node sender/web/test/run-vectors.js /tmp/vd_web_dump.bin

# 用参考实现端到端还原（含 30% 丢帧模拟）
python3 protocol/crosscheck.py /tmp/vd_web_dump.bin \
    --sha $(grep contentSha256 protocol/vectors/e2e.txt | awk '{print $2}') --drop 0.3
```

QR 矩阵层（RS 纠错、交织、放置、掩码、格式/版本信息）已用 macOS CoreImage
`CIDetector`（与 iOS 接收端同源的解码引擎）活体解码验证：V15/23/31/40 四档
与八种掩码的 `errorCorrectedPayload` 均与期望数据码字流逐字节一致。

页面上的「导出帧转储」按钮产出契约第 14 节格式的转储文件，可直接交给
`crosscheck.py` 校验真实播放字节。
