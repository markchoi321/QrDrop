# 二维码文件传输系统

通过二维码在设备间传输文件的Java GUI应用程序，支持大文件分片传输、手动/自动播放控制。

## 功能特性

- 文件自动分片（每片1KB）
- 二维码自动循环播放
- 暂停/继续播放控制
- 上一个/下一个片段手动切换
- 片段列表双击跳转
- 可调节播放间隔（100-30000毫秒）
- 重新开始功能
- MD5文件标识
- CRC32数据校验
- 二维码自适应窗口缩放

## 核心参数

- 分片大小：1024字节/片
- 二维码尺寸：800x800像素
- 默认切换间隔：2000毫秒
- 纠错级别：L级（约7%容错率）
- 字符编码：UTF-8

## 安装依赖

项目使用Maven管理依赖，需要Java 8或更高版本。

```bash
# 编译项目
mvn clean package
```

主要依赖库：
- ZXing 3.5.1（二维码生成）
- Jackson 2.13.4（JSON处理）
- Commons Codec 1.15（Base64编码）

## 使用方法

### 命令行运行

```bash
# 方式1：使用Maven运行
mvn exec:java -Dexec.mainClass="org.file.qrcode.QRCodeGeneratorGUI" -Dexec.args="文件路径"

# 方式2：直接运行编译后的class（需要指定classpath）
java -cp target/classes:依赖jar路径 org.file.qrcode.QRCodeGeneratorGUI 文件路径
```

### 示例

```bash
# 传输文本文件
mvn exec:java -Dexec.mainClass="org.file.qrcode.QRCodeGeneratorGUI" -Dexec.args="test.txt"

# 传输PDF文件
mvn exec:java -Dexec.mainClass="org.file.qrcode.QRCodeGeneratorGUI" -Dexec.args="document.pdf"
```

### GUI界面操作

启动后会显示图形界面，包含：

**左侧：二维码显示区**
- 自动循环显示各个片段的二维码

**右侧：控制面板**
- 暂停/继续按钮：控制自动播放
- 上一个/下一个按钮：手动切换片段
- 间隔调节：输入100-30000毫秒范围的间隔时间
- 重新开始按钮：跳转到第一个片段
- 片段列表：显示所有片段，双击可跳转
- 文件信息：显示文件名、ID、片段数和大小

## 数据格式

每个二维码包含JSON格式的数据片段：

```json
{
  "fileId": "a1b2c3d4e5f6g7h8",
  "fileName": "test.pdf",
  "totalChunks": 50,
  "chunkIndex": 0,
  "data": "SGVsbG8gV29ybGQh...",
  "crc32": 222957957
}
```

字段说明：
- `fileId`：文件MD5的前16位，用于标识文件
- `fileName`：原始文件名
- `totalChunks`：总片段数
- `chunkIndex`：当前片段索引（从0开始）
- `data`：Base64编码的片段数据
- `crc32`：片段数据的CRC32校验值

## 项目结构

```
BinaryQr/
├── pom.xml                                 # Maven配置文件
├── README.md                               # 项目说明文档
├── src/
│   └── main/
│       └── java/
│           └── org/
│               └── file/
│                   └── qrcode/
│                       ├── QRCodeGeneratorGUI.java  # 主程序和GUI界面
│                       └── DataChunk.java           # 数据片段类
└── target/                                 # 编译输出目录
```

## 技术实现

### 文件分片流程

1. 读取文件的所有字节
2. 计算文件内容的MD5值作为文件ID（取前16位）
3. 按1024字节分片
4. 对每个片段：
   - Base64编码
   - 计算CRC32校验值
   - 封装为DataChunk对象
5. 返回片段列表

### 二维码生成

使用ZXing库生成二维码：
- 格式：QR_CODE
- 尺寸：800x800像素
- 边距：2个模块
- 纠错级别：L（低，约7%容错率）
- 编码：UTF-8

### GUI设计

- 使用Swing构建界面
- BorderLayout + BoxLayout混合布局
- Timer定时器实现自动播放
- 自适应缩放二维码以适应窗口大小
- 列表与显示区联动

## 参数调整建议

### 提高识别成功率

如果接收端识别困难，可以调整以下参数：

**减小分片大小**（减少二维码密度）：
```java
private static final int CHUNK_SIZE = 512;  // 从1024改为512
```

**增加二维码尺寸**：
```java
private static final int QR_SIZE = 1000;  // 从800改为1000
```

**提高纠错级别**（代价是数据容量减少）：
```java
hints.put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.M);  // 从L改为M或H
```

**减少切换间隔**（给识别更多时间）：
```java
private static final int DISPLAY_INTERVAL = 300;  // 从2000改为300毫秒
```

### 提高传输速度

如果识别成功率高，想加快传输：

- 减小切换间隔（通过GUI界面调整，或修改DISPLAY_INTERVAL）
- 增加分片大小（最多约2000字节，超过会导致二维码过密）
- 降低纠错级别到L（已是最低）

## 性能参考

基于默认配置的性能估算：

- 分片大小：1024字节
- 切换间隔：2秒
- 有效传输速度：约300字节/秒（18KB/分钟，1MB/小时）
- 10KB文件：约34秒（17个片段）
- 100KB文件：约5.5分钟（167个片段）
- 1MB文件：约56分钟（1747个片段）

注意：实际速度取决于接收端识别成功率和处理速度。

## 使用建议

1. 屏幕亮度调至最高
2. 关闭屏幕自动休眠
3. 确保二维码完整显示在屏幕中
4. 根据接收设备性能调整切换间隔
5. 小文件（<100KB）适合此方式传输
6. 大文件建议使用其他传输方式

## 后续开发方向

- [ ] 开发配套的接收端程序（Java/Python）
- [ ] 支持断点续传
- [ ] 添加传输进度保存/恢复
- [ ] 实现前向纠错码（FEC）
- [ ] 支持数据压缩
- [ ] 添加加密功能
- [ ] 优化二维码生成性能
- [ ] 自适应调整参数

## 常见问题

**Q: 如何选择合适的文件？**
A: 建议传输100KB以内的文件，如小型文档、配置文件、代码文件等。

**Q: 支持什么类型的文件？**
A: 支持任意格式的文件，程序以二进制方式读取。

**Q: 文件ID有什么用？**
A: 用于接收端识别不同文件的片段，避免混淆。

**Q: 为什么使用CRC32而不是MD5？**
A: CRC32计算速度快，足以检测传输错误，且数值较小便于传输。

**Q: 能否同时传输多个文件？**
A: 当前版本不支持，需要依次传输。

## 许可证

本项目仅供学习和研究使用。