//
//  DecodeEngine.swift
//  QrDrop
//
//  解码与持久化的唯一所有者。
//
//  为什么要有这一层：喷泉码的剥离解码不是均匀负载。LT 的雪崩会把绝大部分工作压进
//  收齐前的两三帧里——5 MB 文件（K=17895）实测最后一帧一次剥出 13503 个源块，
//  Release 下 60 ms、Debug 下 800 ms。这活儿只要还在主线程上，就一定会卡住取景与界面。
//
//  所以 sessions / decoder / journal 全部由本 actor 独占，界面不再持有任何会话对象，
//  只按固定节拍取一份不可变快照（SessionSnapshot）。合并（finalize）是唯一的例外：
//  它是一次时长不可预测的 CPU 任务，放在 actor 里会连带堵住扫码与快照，因此丢给
//  detached task，靠 isFinalizing 保证这期间没有第二路会碰那个解码器。
//

import Foundation
import CoreImage

// MARK: - 快照

/// 界面看到的会话，纯值类型。字段名与原先的 ReceiveSession 对齐，便于视图层原样取用。
struct SessionSnapshot: Identifiable, Sendable, Equatable {
    let sessionId: UInt32
    let K: Int
    let T: Int
    let codec: Codec
    let compressed: Bool
    let blocksPerFrame: Int
    let epsilon: Double
    let displayName: String
    /// 元数据里的原始大小，未解析出头部时为 nil
    let originalSize: UInt64?
    let stats: SessionStats
    let solvedCount: Int
    let estimatedNeededBlocks: Int
    let sourceProgress: Double
    let blockProgress: Double
    let isComplete: Bool
    let isFinished: Bool
    let isFinalizing: Bool
    let finalizeProgress: Double
    let savedFileURL: URL?
    let failureMessage: String?
    let finalSize: Int?

    var id: UInt32 { sessionId }
}

/// 旧 JSON 格式文件的快照
struct LegacyFileSnapshot: Identifiable, Sendable, Equatable {
    let fileId: String
    let fileName: String
    let totalChunks: Int
    let receivedChunks: Int

    var id: String { fileId }
    var isComplete: Bool { receivedChunks == totalChunks }
}

/// actor 内产生的日志。跟着快照一起带出来，避免每行日志跳一次主线程
struct EngineLogLine: Sendable {
    let message: String
    let isError: Bool
}

struct EngineSnapshot: Sendable {
    var sessions: [SessionSnapshot] = []
    var legacyFiles: [LegacyFileSnapshot] = []
    /// 自上次取快照以来新产生的日志
    var newLogs: [EngineLogLine] = []
}

// MARK: - 解码 actor

actor DecodeEngine {

    /// 新二进制协议的会话，以 sessionId 为主键
    private var sessions: [UInt32: ReceiveSession] = [:]
    /// 旧 JSON 格式的文件
    private var legacyFiles: [String: LegacyFile] = [:]
    /// 每会话的增量日志写入器，FileHandle 常开
    private var journals: [UInt32: ProgressJournal] = [:]
    /// 待随快照带给界面的日志
    private var pendingLogs: [EngineLogLine] = []

    /// 接收速率统计。自带锁，界面可直接读，不必绕 actor
    nonisolated let throughput = ThroughputMeter()

    /// 增量日志的刷盘间隔。每次只写这段时间内新产生的成果，与已有进度无关
    private let journalFlushInterval: TimeInterval = 1
    /// 日志压实下限：小于它不值得为压实付一次全量写
    private let checkpointFloorBytes = 512 * 1024

    /// 累计写盘字节数（日志追加 + 压实），供实测对比
    private(set) var journalBytesWritten = 0
    private(set) var checkpointCount = 0
    private(set) var checkpointBytesWritten = 0

    // MARK: - 日志

    private func log(_ message: String, isError: Bool = false) {
        pendingLogs.append(EngineLogLine(message: message, isError: isError))
        if pendingLogs.count > 500 { pendingLogs.removeFirst(100) }
    }

    // MARK: - 快照

    func snapshot() -> EngineSnapshot {
        var out = EngineSnapshot()
        out.sessions = sessions.values
            .sorted { $0.sessionId < $1.sessionId }
            .map(Self.snapshot(of:))
        out.legacyFiles = legacyFiles.values
            .sorted { $0.fileId < $1.fileId }
            .map { LegacyFileSnapshot(fileId: $0.fileId, fileName: $0.fileName,
                                      totalChunks: $0.totalChunks, receivedChunks: $0.chunks.count) }
        out.newLogs = pendingLogs
        pendingLogs.removeAll(keepingCapacity: true)
        return out
    }

    private static func snapshot(of s: ReceiveSession) -> SessionSnapshot {
        SessionSnapshot(sessionId: s.sessionId,
                        K: s.K,
                        T: s.T,
                        codec: s.codec,
                        compressed: s.compressed,
                        blocksPerFrame: s.blocksPerFrame,
                        epsilon: s.epsilon,
                        displayName: s.displayName,
                        originalSize: s.meta?.originalSize,
                        stats: s.stats,
                        solvedCount: s.decoder.solvedCount,
                        estimatedNeededBlocks: s.estimatedNeededBlocks,
                        sourceProgress: s.sourceProgress,
                        blockProgress: s.blockProgress,
                        isComplete: s.isComplete,
                        isFinished: s.isFinished,
                        isFinalizing: s.isFinalizing,
                        finalizeProgress: s.finalizeProgress,
                        savedFileURL: s.savedFileURL,
                        failureMessage: s.failureMessage,
                        finalSize: s.finalSize)
    }

    var isEmpty: Bool { sessions.isEmpty && legacyFiles.isEmpty }
    var sessionCount: Int { sessions.count }

    func sessionSnapshot(_ sessionId: UInt32) -> SessionSnapshot? {
        sessions[sessionId].map(Self.snapshot(of:))
    }

    /// 中间态（编码块 / 源块 / 消元基）是否已释放。合并落盘后才为 true
    func decoderReleased(_ sessionId: UInt32) -> Bool {
        sessions[sessionId]?.decoder.isReleased ?? false
    }

    // MARK: - 载荷分流（设计 12.1）

    /// 吃下一批识别结果，返回是否有新块被接受
    @discardableResult
    func process(_ payloads: [Data]) -> Bool {
        var gained = false
        for payload in payloads where processPayload(payload) { gained = true }
        return gained
    }

    /// 按首字节分流：0x56 走新二进制协议，0x7B（'{'）走旧 JSON 分支
    @discardableResult
    func processPayload(_ payload: Data) -> Bool {
        guard let first = payload.first else { return false }
        switch first {
        case FrameParser.magic:
            return processBinaryFrame([UInt8](payload))
        case 0x7B:
            guard let text = String(data: payload, encoding: .utf8) else { return false }
            return processLegacyJSON(text)
        default:
            return false
        }
    }

    // MARK: - 新二进制协议

    private func processBinaryFrame(_ bytes: [UInt8]) -> Bool {
        guard let frame = FrameParser.parse(bytes) else {
            // 整帧丢弃：长度 / magic / 版本 / CRC 任一失败
            if bytes.count >= 6 {
                let sid = ByteOps.readUInt32(bytes, 2)
                sessions[sid]?.stats.framesRejected += 1
            }
            return false
        }

        let session: ReceiveSession
        if let existing = sessions[frame.sessionId] {
            // 参数不一致说明 sessionId 撞车，丢弃该帧而不是污染已有会话
            guard existing.K == frame.K, existing.T == frame.T, existing.codec == frame.codec else {
                existing.stats.framesRejected += 1
                log("会话 \(SessionId.hex(frame.sessionId)) 参数不一致，整帧丢弃", isError: true)
                return false
            }
            session = existing
        } else {
            session = ReceiveSession(frame: frame)
            sessions[frame.sessionId] = session
            log("新会话 \(SessionId.hex(frame.sessionId))：K=\(frame.K) T=\(frame.T) \(frame.codec.displayName)")
        }

        // 已完成或正在后台还原的会话不再吃新块：既是白做功，
        // 还原期间那个解码器归后台任务独占，更不能碰
        guard !session.isComplete, !session.isFinalizing else {
            session.stats.framesAccepted += 1
            return false
        }

        // 只把去重后新增的块计入速率，重复帧不算（见 ThroughputMeter 的说明）
        let uniqueBefore = session.stats.blocksUnique
        let gained = session.ingest(frame)
        let newBlocks = session.stats.blocksUnique - uniqueBefore
        if newBlocks > 0 {
            throughput.record(bytes: newBlocks * session.T)
        }

        if session.isComplete && !session.isFinished {
            // 收齐后不自动合并：合并是一次时长不可预测的 CPU 任务（解方程的回代是 O(K^2)），
            // 交给用户在主界面手动触发，避免它在传输刚结束时突然占住机器。
            // 但必须立刻落一次盘，否则退出后这些块就白收了。
            flushJournal(session, force: true)
            log("已收齐 \(session.displayName)：\(session.K) 个源块，等待手动合并")
        } else if gained {
            flushJournal(session, force: false)
        }
        return gained
    }

    // MARK: - 合并

    /// 用户手动触发合并（收齐之后、中止之后、失败之后都走这里）。
    ///
    /// 拼接 -> parseStream -> 解压 -> 校验 SHA-256 -> 落盘 -> 删除进度文件。
    /// 重活放 detached task：解方程的回代是 O(K^2) 次块异或，K=2503 时实测 Release 约 90 ms、
    /// Debug 达 6–8 秒。放在 actor 内会连带堵住扫码与快照，界面同样会冻住。
    /// await 期间 actor 是释放的，而 isFinalizing 保证这期间没有第二路会碰这个解码器。
    func startFinalize(_ sessionId: UInt32) async {
        guard let session = sessions[sessionId],
              !session.isFinished, !session.isFinalizing, session.isComplete else { return }

        session.failureMessage = nil
        session.isFinalizing = true
        let cancelFlag = CancellationFlag()
        let progressBox = ProgressBox()
        session.finalizeCancel = cancelFlag
        session.finalizeProgressBox = progressBox

        let decoder = session.decoder
        let startedAt = Date()
        log("开始还原 \(SessionId.hex(sessionId))：K=\(session.K) T=\(session.T) \(session.codec.displayName)")

        let outcome = await Task.detached(priority: .userInitiated) { () -> FinalizeOutcome in
            var timing = FinalizeTiming()
            do {
                var mark = Date()
                let assembled = decoder.assemble(progress: { progressBox.set($0) },
                                                 isCancelled: { cancelFlag.isSet })
                timing.assemble = Date().timeIntervalSince(mark)
                guard let assembled else { throw StreamError.cancelled }

                mark = Date()
                let parsed = try StreamCodec.parseStream(assembled)
                timing.parse = Date().timeIntervalSince(mark)

                mark = Date()
                let digestOK = StreamCodec.sha256(parsed.content) == parsed.meta.sha256
                timing.hash = Date().timeIntervalSince(mark)
                guard digestOK else { throw StreamError.digestMismatch }

                mark = Date()
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("received", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(DecodeEngine.sanitize(parsed.meta.fileName))
                try Data(parsed.content).write(to: url, options: .atomic)
                timing.write = Date().timeIntervalSince(mark)
                return .success(meta: parsed.meta, size: parsed.content.count, url: url, timing: timing)
            } catch {
                return .failure(error)
            }
        }.value

        session.isFinalizing = false
        session.finalizeCancel = nil
        session.finalizeProgressBox = nil
        let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)

        switch outcome {
        case .success(let meta, let size, let url, let t):
            session.meta = meta
            session.savedFileURL = url
            session.finalSize = size
            // 中间态到此为止：编码块 / 源块 / 消元基全部释放，
            // 大文件下这部分是文件本身的 1.3–1.5 倍，留着会一直压着内存
            session.decoder.releaseStorage()
            closeJournal(sessionId)
            ProgressStore.remove(sessionId: sessionId)
            log("接收完成：\(meta.fileName)（\(size) 字节，SHA-256 通过）")
            log(String(format: "  耗时 合计%dms = 拼接%.0f + 解流%.0f + 校验%.0f + 写盘%.0f",
                       totalMs, t.assemble * 1000, t.parse * 1000, t.hash * 1000, t.write * 1000))
            log("  已释放中间态，\(Diagnostics.memoryTag())")
        case .failure(let error):
            if case StreamError.cancelled = error {
                session.failureMessage = nil
                log("会话 \(SessionId.hex(sessionId)) 合并已中止", isError: true)
            } else {
                session.failureMessage = error.localizedDescription
                log("会话 \(SessionId.hex(sessionId)) 还原失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    /// 用户中止合并
    func cancelFinalize(_ sessionId: UInt32) {
        guard let session = sessions[sessionId], session.isFinalizing else { return }
        session.finalizeCancel?.set()
        log("正在中止 \(SessionId.hex(sessionId)) 的合并…")
    }

    private struct FinalizeTiming {
        var assemble = 0.0, parse = 0.0, hash = 0.0, write = 0.0
    }

    private enum FinalizeOutcome: @unchecked Sendable {
        case success(meta: StreamMeta, size: Int, url: URL, timing: FinalizeTiming)
        case failure(Error)
    }

    /// 去掉路径分隔符，避免恶意文件名写到目录外
    nonisolated static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return cleaned.isEmpty ? "received.bin" : cleaned
    }

    // MARK: - 旧 JSON 分支

    private func processLegacyJSON(_ text: String) -> Bool {
        guard let jsonData = text.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(QRChunk.self, from: jsonData) else {
            return false
        }
        let file = legacyFiles[chunk.fileId] ?? {
            let f = LegacyFile(fileId: chunk.fileId, fileName: chunk.fileName, totalChunks: chunk.totalChunks)
            legacyFiles[chunk.fileId] = f
            return f
        }()
        if file.chunks[chunk.chunkIndex] != nil { return false }

        guard let dataBytes = Data(base64Encoded: chunk.data) else {
            log("旧格式片段 \(chunk.chunkIndex) base64 解码失败", isError: true)
            return false
        }
        guard ByteOps.crc32([UInt8](dataBytes)) == chunk.crc32 else {
            log("旧格式片段 \(chunk.chunkIndex) CRC32 校验失败", isError: true)
            return false
        }
        file.chunks[chunk.chunkIndex] = dataBytes
        throughput.record(bytes: dataBytes.count)
        log("旧格式片段 \(chunk.chunkIndex + 1)/\(chunk.totalChunks) - \(chunk.fileName)")
        if file.isComplete { log("旧格式文件 \(chunk.fileName) 接收完成") }
        return true
    }

    /// 按顺序拼出旧格式文件，供导出使用
    func assembleLegacy(fileId: String) -> (fileName: String, data: Data)? {
        guard let file = legacyFiles[fileId] else { return nil }
        var out = Data()
        for i in 0..<file.totalChunks {
            if let chunk = file.chunks[i] { out.append(chunk) }
        }
        return (file.fileName, out)
    }

    // MARK: - 进度持久化

    /// 把解码器新产生的成果追加进日志。写入量正比于本次新增，与已有进度无关。
    /// 日志涨过状态本身时才压实成一份 checkpoint——写放大因此钳在 2 倍以内。
    private func flushJournal(_ session: ReceiveSession, force: Bool) {
        guard !session.decoder.isReleased else { return }
        guard session.decoder.journalCount > 0 else { return }
        guard force || Date().timeIntervalSince(session.lastSavedAt) > journalFlushInterval else { return }

        let started = Date()
        do {
            let journal = try openJournal(session)
            let before = journal.byteCount
            try journal.append(session.decoder.takeJournal(), stats: session.stats)
            session.lastSavedAt = Date()
            journalBytesWritten += journal.byteCount - before

            let ms = Diagnostics.elapsedMs(since: started)
            if ms > 50 {
                log("进度日志写入偏慢：\(SessionId.hex(session.sessionId)) 耗时 \(ms) ms")
            }
            if journal.byteCount > max(checkpointFloorBytes, session.decoder.snapshotByteEstimate) {
                checkpoint(session)
            }
        } catch {
            log("进度日志写入失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func closeJournal(_ sessionId: UInt32) {
        journals[sessionId]?.close()
        journals[sessionId] = nil
    }

    private func openJournal(_ session: ReceiveSession) throws -> ProgressJournal {
        if let existing = journals[session.sessionId] { return existing }
        let journal = try ProgressJournal(session: session)
        journals[session.sessionId] = journal
        return journal
    }

    /// 压实：写一份全量 checkpoint 并清空日志
    private func checkpoint(_ session: ReceiveSession) {
        let started = Date()
        closeJournal(session.sessionId)
        do {
            try ProgressStore.save(session)
            checkpointCount += 1
            let size = (try? Data(contentsOf: ProgressStore.fileURL(for: session.sessionId)).count) ?? 0
            checkpointBytesWritten += size
            log("进度压实 \(SessionId.hex(session.sessionId))：\(size) 字节，"
                + "耗时 \(Diagnostics.elapsedMs(since: started)) ms，"
                + "累计写盘 日志\(journalBytesWritten) + 压实\(checkpointBytesWritten) 字节")
        } catch {
            log("进度压实失败：\(error.localizedDescription)", isError: true)
        }
    }

    /// App 进入后台时把各会话未落盘的增量刷出去
    func saveAllProgress(force: Bool) {
        let started = Date()
        var saved = 0
        // 已合并落盘的会话没有中间态可存，其进度文件在落盘时已删除；
        // 收齐但尚未合并的仍必须保存，否则退出即丢
        for session in sessions.values where !session.isFinished && !session.decoder.isReleased {
            guard session.decoder.journalCount > 0 else { continue }
            flushJournal(session, force: force)
            saved += 1
        }
        let ms = Diagnostics.elapsedMs(since: started)
        if force && (saved > 0 || ms > 50) {
            log("保存进度：\(saved) 个会话，耗时 \(ms) ms，\(Diagnostics.memoryTag())")
        }
    }

    /// App 启动时扫描目录恢复：checkpoint 装底，增量日志重放在上
    func restoreProgress() {
        let started = Date()
        let loaded = ProgressStore.loadAll()
        for session in loaded.sessions where sessions[session.sessionId] == nil {
            sessions[session.sessionId] = session
        }
        if !loaded.sessions.isEmpty {
            log("已恢复 \(loaded.sessions.count) 个会话进度，耗时 \(Diagnostics.elapsedMs(since: started)) ms")
        }
        for msg in loaded.failures {
            log("进度文件读取失败 \(msg)", isError: true)
        }
    }

    // MARK: - 导出/导入（跨设备迁移，与磁盘格式相同，sessionCount 可 > 1）

    func encodeProgress() -> Data {
        ProgressStore.encode(sessions.values
            .sorted { $0.sessionId < $1.sessionId }
            .filter { !$0.isComplete })
    }

    func loadProgress(from data: Data) throws {
        let restored = try ProgressStore.decode(data)
        for session in restored {
            sessions[session.sessionId] = session
            // 导入即压实：先关掉可能存在的旧日志句柄，save 会把日志文件一并删掉
            closeJournal(session.sessionId)
            try? ProgressStore.save(session)
        }
        log("进度已导入，包含 \(restored.count) 个会话")
    }

    // MARK: - 清理

    /// 清空全部接收数据：会话列表、旧格式文件、进度文件、已落盘的最终文件。
    ///
    /// 三处必须一起清。只删进度文件而留下内存里的 sessions，下一次刷盘会把
    /// 它们原样写回，等于没清；只清 sessions 而留下 received/ 下的最终文件，
    /// 那些文件在 app 内再也没有入口可以访问到，只能占着空间。
    func clearAll() {
        // 句柄必须先关：还开着的话删掉的只是目录项，文件本身要等句柄释放才真正消失
        for journal in journals.values { journal.close() }
        journals.removeAll()
        journalBytesWritten = 0
        checkpointCount = 0
        checkpointBytesWritten = 0
        sessions.removeAll()
        legacyFiles.removeAll()
        throughput.reset()
        let progressCount = ProgressStore.clearAll()
        let fileCount = DecodeEngine.clearReceivedFiles()
        log("数据已清空：\(progressCount) 个进度文件，\(fileCount) 个已接收文件")
    }

    /// 删除 received/ 目录下已落盘的最终文件，返回删除个数
    private static func clearReceivedFiles() -> Int {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("received", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                     includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for url in urls {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
