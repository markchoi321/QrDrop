//
//  ReceiveSession.swift
//  QrBinary
//
//  L5 会话层。对应设计文档 7.3。
//  会话参数由帧头确定且不可变；解码状态与统计随帧推进。
//

import Foundation

/// 会话统计，同时用于 11.1 识别率标定
struct SessionStats {
    var framesAccepted: Int = 0      // 通过 CRC32 的帧数
    var framesRejected: Int = 0      // 校验失败的帧数
    var blocksReceived: Int = 0      // 收到的编码块总数（含重复）
    var blocksDuplicate: Int = 0     // 重复 blockId 数
    var maxBlockId: UInt32 = 0       // 观察到的最大 blockId
    var firstSeenAt: Date = Date()
    var lastSeenAt: Date = Date()

    /// 唯一编码块数
    var blocksUnique: Int { blocksReceived - blocksDuplicate }

    /// 估算单帧成功率：接收端实收帧数 / 发送端已播帧数
    /// 发送端已播帧数由 maxBlockId 与每帧块数 m 反推
    func estimatedFrameSuccessRate(blocksPerFrame m: Int) -> Double {
        guard maxBlockId > 0, m > 0 else { return 0 }
        let sentFrames = Double(maxBlockId + 1) / Double(m)
        return sentFrames > 0 ? Double(framesAccepted) / sentFrames : 0
    }
}

/// 单个接收会话
final class ReceiveSession: Identifiable {

    // 不可变会话参数，由帧头确定
    let sessionId: UInt32
    let K: Int
    let T: Int
    let codec: Codec
    let compressed: Bool

    // 解码状态
    let decoder: BlockDecoder

    // 元数据与统计
    var meta: StreamMeta?
    var stats: SessionStats
    /// 最近一帧的块数 m，用于估算发送端已播帧数
    var blocksPerFrame: Int = 1
    /// 完成后落盘的文件位置
    var savedFileURL: URL?
    var failureMessage: String?
    /// 正在后台还原（拼接 / 解压 / 校验 / 落盘）。期间不得再喂新块，
    /// 否则后台读取解码器状态的同时主线程在改它。
    var isFinalizing: Bool = false
    /// 还原进度 0…1，仅解方程的回代会真正推进
    var finalizeProgress: Double = 0
    /// 用户请求中止合并。后台线程轮询，故用带锁的标志而非裸 Bool
    var finalizeCancel: CancellationFlag?
    /// 最终文件字节数。解码状态释放后由它提供展示数据
    var finalSize: Int?

    /// 已完成并落盘。此后中间态（编码块 / 源块 / 消元基）已释放，只留最终文件与统计
    var isFinished: Bool { savedFileURL != nil }
    /// 上次写进度文件的时间
    var lastSavedAt: Date = .distantPast

    var id: UInt32 { sessionId }

    init(sessionId: UInt32, K: Int, T: Int, codec: Codec, compressed: Bool,
         stats: SessionStats = SessionStats()) {
        self.sessionId = sessionId
        self.K = K
        self.T = T
        self.codec = codec
        self.compressed = compressed
        self.stats = stats
        switch codec {
        case .linearSolve: self.decoder = LinearSolveDecoder(K: K, T: T)
        case .peeling: self.decoder = PeelingDecoder(K: K, T: T)
        }
    }

    convenience init(frame: ParsedFrame) {
        self.init(sessionId: frame.sessionId, K: frame.K, T: frame.T,
                  codec: frame.codec, compressed: frame.compressed)
        blocksPerFrame = frame.m
    }

    // MARK: - 进度

    var isComplete: Bool { decoder.isComplete }
    /// 次要指标：已解出源块（解方程方案为消元秩）占 K 的比例
    var sourceProgress: Double { K > 0 ? Double(decoder.solvedCount) / Double(K) : 0 }

    /// ε：解方程 2/K，剥洋葱 1.85/K^0.37，K ≤ 1 时取 0（CONTRACT 第 5 节）
    var epsilon: Double {
        guard K > 1 else { return 0 }
        return codec == .linearSolve ? 2.0 / Double(K) : 1.85 / pow(Double(K), 0.37)
    }

    /// 预计所需编码块数 = ceil(K × (1 + ε))
    var estimatedNeededBlocks: Int {
        max(K, Int((Double(K) * (1 + epsilon)).rounded(.up)))
    }

    /// 主进度：已接收编码块 / 预计所需
    var blockProgress: Double {
        let need = estimatedNeededBlocks
        guard need > 0 else { return 0 }
        return min(1.0, Double(stats.blocksUnique) / Double(need))
    }

    var displayName: String {
        meta?.fileName ?? "会话 \(SessionId.hex(sessionId))"
    }

    // MARK: - 帧接收

    /// 吃下一帧的全部编码块，返回是否有新块被接受
    func ingest(_ frame: ParsedFrame) -> Bool {
        blocksPerFrame = frame.m
        stats.framesAccepted += 1
        stats.lastSeenAt = Date()

        var gained = false
        for i in 0..<frame.m {
            let bid = frame.blockId(i)
            stats.blocksReceived += 1
            if bid > stats.maxBlockId { stats.maxBlockId = bid }
            if decoder.add(blockId: bid, payload: frame.block(i)) {
                gained = true
            } else {
                stats.blocksDuplicate += 1
            }
        }
        if gained { tryExtractMeta() }
        return gained
    }

    /// 解出块 0 起的连续源块后即可解析 StreamHeader；解方程方案要到完成才有源块
    func tryExtractMeta() {
        guard meta == nil else { return }
        guard let peeling = decoder as? PeelingDecoder else {
            if decoder.isComplete, let m = try? StreamCodec.parseHeader(decoder.assemble()) {
                meta = m
            }
            return
        }
        var buf = [UInt8]()
        var i = 0
        // 连续块凑够 54 + fileNameLen 即可解析出头部
        while i < K, let blk = peeling.solvedBlock(i) {
            buf.append(contentsOf: blk)
            i += 1
            if buf.count >= StreamCodec.headerFixedLength {
                if let m = try? StreamCodec.parseHeader(buf) {
                    meta = m
                    return
                }
            }
        }
    }

    // MARK: - 完成

    /// 拼接源块 -> parseStream -> 解压 -> 校验 SHA-256
    func finalizeContent() throws -> (meta: StreamMeta, content: [UInt8]) {
        let assembled = decoder.assemble()
        let parsed = try StreamCodec.parseStream(assembled)
        guard StreamCodec.sha256(parsed.content) == parsed.meta.sha256 else {
            throw StreamError.digestMismatch
        }
        meta = parsed.meta
        return parsed
    }
}
