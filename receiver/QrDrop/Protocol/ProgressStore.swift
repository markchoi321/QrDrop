//
//  ProgressStore.swift
//  QrDrop
//
//  进度持久化。严格对应 CONTRACT.md 第 11 节的二进制格式（全大端，不用 JSON）。
//  位置：Documents/progress/<sessionId 8位小写hex>.vdpg（checkpoint）与同名 .vdlog（增量日志）。
//
//  v2 改为增量日志：热路径只把新产生的成果追加到 .vdlog，写入量正比于新增数据而非已有进度；
//  日志涨到超过状态本身时才压实成一份 .vdpg 并清空日志，写放大因此被钳在 2 倍以内。
//  checkpoint 与日志共用同一套记录，checkpoint 就是日志压实后的形态。
//

import Foundation

enum ProgressStoreError: Error, LocalizedError {
    case badMagic
    case unsupportedVersion(Int)
    case truncated
    case unknownRecord(UInt8)

    var errorDescription: String? {
        switch self {
        case .badMagic: return "进度文件 magic 不匹配"
        case .unsupportedVersion(let v): return "进度文件版本不支持: \(v)"
        case .truncated: return "进度文件被截断"
        case .unknownRecord(let t): return "进度文件含未知记录类型: \(t)"
        }
    }
}

/// 记录类型标签
private enum RecordTag: UInt8 {
    case seen = 0x01
    case seenMap = 0x02
    case solved = 0x03
    case rawBlock = 0x04
    case pending = 0x05
    case basis = 0x06
    /// 仅日志使用，恢复时以最后一条为准
    case stats = 0x07
}

enum ProgressStore {

    static let magic: [UInt8] = [0x56, 0x44, 0x50, 0x47]     // "VDPG"
    static let logMagic: [UInt8] = [0x56, 0x44, 0x4C, 0x47]  // "VDLG"
    static let formatVersion: UInt16 = 2
    static let statsLength = 40
    /// 日志头：magic(4) version(2) sessionId(4) K(3) T(2) flags(1)
    static let logHeaderLength = 16

    // MARK: - 目录

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("progress", isDirectory: true)
    }

    static func fileURL(for sessionId: UInt32) -> URL {
        directory.appendingPathComponent("\(SessionId.hex(sessionId)).vdpg")
    }

    static func logURL(for sessionId: UInt32) -> URL {
        directory.appendingPathComponent("\(SessionId.hex(sessionId)).vdlog")
    }

    static func ensureDirectory() throws {
        let dir = directory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - 会话头与统计

    private static func sessionFlags(_ s: ReceiveSession) -> UInt8 {
        var flags: UInt8 = 0
        if s.compressed { flags |= 0x01 }
        if s.meta != nil { flags |= 0x02 }
        if s.codec == .peeling { flags |= 0x04 }
        return flags
    }

    private static func appendStats(_ out: inout [UInt8], _ s: SessionStats) {
        ByteOps.appendUInt32(&out, UInt32(s.framesAccepted))
        ByteOps.appendUInt32(&out, UInt32(s.framesRejected))
        ByteOps.appendUInt32(&out, UInt32(s.blocksReceived))
        ByteOps.appendUInt32(&out, UInt32(s.blocksDuplicate))
        ByteOps.appendUInt32(&out, s.maxBlockId)
        ByteOps.appendUInt32(&out, 0)                                   // reserved
        ByteOps.appendDouble(&out, s.firstSeenAt.timeIntervalSince1970)
        ByteOps.appendDouble(&out, s.lastSeenAt.timeIntervalSince1970)
    }

    private static func readStats(_ b: [UInt8], _ off: Int) -> SessionStats {
        var stats = SessionStats()
        stats.framesAccepted = Int(ByteOps.readUInt32(b, off))
        stats.framesRejected = Int(ByteOps.readUInt32(b, off + 4))
        stats.blocksReceived = Int(ByteOps.readUInt32(b, off + 8))
        stats.blocksDuplicate = Int(ByteOps.readUInt32(b, off + 12))
        stats.maxBlockId = ByteOps.readUInt32(b, off + 16)
        stats.firstSeenAt = Date(timeIntervalSince1970: ByteOps.readDouble(b, off + 24))
        stats.lastSeenAt = Date(timeIntervalSince1970: ByteOps.readDouble(b, off + 32))
        return stats
    }

    // MARK: - 记录编解码

    /// 系数向量的字节数，与 BitSet.littleEndianBytes 一致
    private static func coeffBytes(_ K: Int) -> Int { (K + 7) / 8 }

    static func encodeRecords(_ records: [ProgressRecord], K: Int, T: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(records.count * (T + 8))
        _ = K
        for r in records { appendRecord(&out, r) }
        return out
    }

    /// 记录里不出现 K：系数向量按 BitSet.littleEndianBytes 定长写出，长度由读侧的 K 决定
    private static func appendRecord(_ out: inout [UInt8], _ r: ProgressRecord) {
        switch r {
        case .seen(let blockId):
            out.append(RecordTag.seen.rawValue)
            ByteOps.appendUInt32(&out, blockId)
        case .seenMap(let base, let bitCount, let bits):
            out.append(RecordTag.seenMap.rawValue)
            ByteOps.appendUInt32(&out, base)
            ByteOps.appendUInt32(&out, UInt32(bitCount))
            out.append(contentsOf: bits)
        case .solved(let index, let data):
            out.append(RecordTag.solved.rawValue)
            ByteOps.appendUInt24(&out, UInt32(index))
            out.append(contentsOf: data)
        case .rawBlock(let blockId, let payload):
            out.append(RecordTag.rawBlock.rawValue)
            ByteOps.appendUInt32(&out, blockId)
            out.append(contentsOf: payload)
        case .pending(let blockId, let neighbors, let payload):
            out.append(RecordTag.pending.rawValue)
            ByteOps.appendUInt32(&out, blockId)
            ByteOps.appendUInt16(&out, UInt16(neighbors.count))
            for i in neighbors { ByteOps.appendUInt24(&out, UInt32(i)) }
            out.append(contentsOf: payload)
        case .basis(let pivot, let coeff, let data):
            out.append(RecordTag.basis.rawValue)
            ByteOps.appendUInt24(&out, UInt32(pivot))
            // 系数向量按位图存，比逐个置位下标存 3 字节小一个数量级
            out.append(contentsOf: coeff.littleEndianBytes)
            out.append(contentsOf: data)
        }
    }

    static func appendStatsRecord(_ out: inout [UInt8], _ stats: SessionStats) {
        out.append(RecordTag.stats.rawValue)
        appendStats(&out, stats)
    }

    /// 读取记录区。
    /// - Parameters:
    ///   - count: checkpoint 已知记录条数；日志传 nil，一直读到缓冲区末尾
    ///   - tolerateTruncation: 日志可能在崩溃时留下半条记录，容忍并丢弃末尾残片
    private static func readRecords(_ b: [UInt8], from start: Int, count: Int?,
                                    K: Int, T: Int,
                                    tolerateTruncation: Bool) throws
        -> (records: [ProgressRecord], stats: SessionStats?, next: Int) {

        var off = start
        var records: [ProgressRecord] = []
        var stats: SessionStats?
        if let count { records.reserveCapacity(count) }
        let cw = coeffBytes(K)
        var read = 0

        while count == nil ? off < b.count : read < count! {
            let recordStart = off
            // 缺字节时：日志停在此处，checkpoint 视为损坏
            func need(_ n: Int) throws -> Bool {
                guard off + n <= b.count else {
                    if tolerateTruncation { return false }
                    throw ProgressStoreError.truncated
                }
                return true
            }

            guard try need(1) else { off = recordStart; break }
            let raw = b[off]; off += 1
            guard let tag = RecordTag(rawValue: raw) else {
                throw ProgressStoreError.unknownRecord(raw)
            }

            switch tag {
            case .seen:
                guard try need(4) else { off = recordStart; break }
                records.append(.seen(blockId: ByteOps.readUInt32(b, off))); off += 4
            case .seenMap:
                guard try need(8) else { off = recordStart; break }
                let base = ByteOps.readUInt32(b, off)
                let bitCount = Int(ByteOps.readUInt32(b, off + 4))
                let n = (bitCount + 7) / 8
                guard bitCount >= 0, try need(8 + n) else { off = recordStart; break }
                off += 8
                records.append(.seenMap(base: base, bitCount: bitCount,
                                        bits: Array(b[off..<(off + n)])))
                off += n
            case .solved:
                guard try need(3 + T) else { off = recordStart; break }
                let index = Int(ByteOps.readUInt24(b, off)); off += 3
                records.append(.solved(index: index, data: Array(b[off..<(off + T)])))
                off += T
            case .rawBlock:
                guard try need(4 + T) else { off = recordStart; break }
                let blockId = ByteOps.readUInt32(b, off); off += 4
                records.append(.rawBlock(blockId: blockId, payload: Array(b[off..<(off + T)])))
                off += T
            case .pending:
                guard try need(6) else { off = recordStart; break }
                let blockId = ByteOps.readUInt32(b, off)
                let degree = Int(ByteOps.readUInt16(b, off + 4))
                guard try need(6 + degree * 3 + T) else { off = recordStart; break }
                off += 6
                var neighbors: [Int] = []
                neighbors.reserveCapacity(degree)
                for _ in 0..<degree {
                    neighbors.append(Int(ByteOps.readUInt24(b, off))); off += 3
                }
                records.append(.pending(blockId: blockId, neighbors: neighbors,
                                        payload: Array(b[off..<(off + T)])))
                off += T
            case .basis:
                guard try need(3 + cw + T) else { off = recordStart; break }
                let pivot = Int(ByteOps.readUInt24(b, off)); off += 3
                let coeff = BitSet(bitCount: K, littleEndianBytes: Array(b[off..<(off + cw)]))
                off += cw
                records.append(.basis(pivot: pivot, coeff: coeff, data: Array(b[off..<(off + T)])))
                off += T
            case .stats:
                guard try need(statsLength) else { off = recordStart; break }
                stats = readStats(b, off)
                off += statsLength
            }

            // need 失败时上面已把 off 回退到记录起点，到这里说明日志末尾残缺
            if off == recordStart { break }
            read += 1
        }

        if let count, read < count { throw ProgressStoreError.truncated }
        return (records, stats, off)
    }

    // MARK: - checkpoint 编码

    /// 打包多个会话，sessionCount 可 > 1，用于跨设备迁移导出
    static func encode(_ sessions: [ReceiveSession]) -> Data {
        var out: [UInt8] = []
        out.append(contentsOf: magic)
        ByteOps.appendUInt16(&out, formatVersion)
        ByteOps.appendUInt16(&out, UInt16(min(sessions.count, Int(UInt16.max))))
        for s in sessions { appendSession(&out, s) }
        return Data(out)
    }

    private static func appendSession(_ out: inout [UInt8], _ s: ReceiveSession) {
        ByteOps.appendUInt32(&out, s.sessionId)
        ByteOps.appendUInt24(&out, UInt32(s.K))
        ByteOps.appendUInt16(&out, UInt16(s.T))
        out.append(sessionFlags(s))

        let metaBytes = s.meta?.rawHeader ?? []
        ByteOps.appendUInt16(&out, UInt16(metaBytes.count))
        out.append(contentsOf: metaBytes)

        appendStats(&out, s.stats)

        let records = s.decoder.snapshotRecords()
        ByteOps.appendUInt32(&out, UInt32(records.count))
        out.append(contentsOf: encodeRecords(records, K: s.K, T: s.T))
    }

    // MARK: - checkpoint 解码

    static func decode(_ data: Data) throws -> [ReceiveSession] {
        let b = [UInt8](data)
        guard b.count >= 8 else { throw ProgressStoreError.truncated }
        guard Array(b[0..<4]) == magic else { throw ProgressStoreError.badMagic }
        let version = ByteOps.readUInt16(b, 4)
        guard version == formatVersion else { throw ProgressStoreError.unsupportedVersion(Int(version)) }
        let count = Int(ByteOps.readUInt16(b, 6))

        var off = 8
        var out: [ReceiveSession] = []
        for _ in 0..<count {
            let (session, next) = try decodeSession(b, off)
            out.append(session)
            off = next
        }
        return out
    }

    private static func decodeSession(_ b: [UInt8], _ start: Int) throws -> (ReceiveSession, Int) {
        var off = start
        func need(_ n: Int) throws {
            guard off + n <= b.count else { throw ProgressStoreError.truncated }
        }

        try need(12)
        let sessionId = ByteOps.readUInt32(b, off); off += 4
        let K = Int(ByteOps.readUInt24(b, off)); off += 3
        let T = Int(ByteOps.readUInt16(b, off)); off += 2
        let flags = b[off]; off += 1
        let metaLen = Int(ByteOps.readUInt16(b, off)); off += 2

        guard K > 0, T > 0 else { throw ProgressStoreError.truncated }
        let compressed = flags & 0x01 != 0
        let codec: Codec = (flags & 0x04 != 0) ? .peeling : .linearSolve

        try need(metaLen)
        var meta: StreamMeta?
        if metaLen > 0 {
            if let m = try? StreamCodec.parseHeader(Array(b[off..<(off + metaLen)])) { meta = m }
            off += metaLen
        }

        try need(statsLength)
        let stats = readStats(b, off)
        off += statsLength

        try need(4)
        let recordCount = Int(ByteOps.readUInt32(b, off)); off += 4
        let parsed = try readRecords(b, from: off, count: recordCount,
                                     K: K, T: T, tolerateTruncation: false)
        off = parsed.next

        let session = ReceiveSession(sessionId: sessionId, K: K, T: T,
                                     codec: codec, compressed: compressed, stats: stats)
        session.meta = meta
        session.decoder.replay(parsed.records)
        session.lastSavedAt = Date()
        return (session, off)
    }

    // MARK: - 磁盘读写

    /// 写 checkpoint 并清空日志。压实点，代价是一次全量写，因此只在日志涨过状态本身时调用
    static func save(_ session: ReceiveSession) throws {
        try ensureDirectory()
        let data = encode([session])
        try data.write(to: fileURL(for: session.sessionId), options: .atomic)
        // 先落 checkpoint 再清日志：中间崩溃只会留下一段过期日志，重放时会被 seen 去重挡掉
        try? FileManager.default.removeItem(at: logURL(for: session.sessionId))
        session.lastSavedAt = Date()
    }

    /// App 启动时扫描目录恢复全部会话：先装 checkpoint，再把各自的增量日志重放上去
    static func loadAll() -> (sessions: [ReceiveSession], failures: [String]) {
        var byId: [UInt32: ReceiveSession] = [:]
        var order: [UInt32] = []
        var failures: [String] = []
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil) else {
            return ([], [])
        }

        for url in items where url.pathExtension == "vdpg" {
            do {
                let data = try Data(contentsOf: url)
                for s in try decode(data) where byId[s.sessionId] == nil {
                    byId[s.sessionId] = s
                    order.append(s.sessionId)
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        for url in items where url.pathExtension == "vdlog" {
            do {
                if let sid = try replayLog(at: url, into: &byId) {
                    if !order.contains(sid) { order.append(sid) }
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return (order.compactMap { byId[$0] }, failures)
    }

    /// 日志头：magic / 版本 / 会话参数
    static func logHeader(_ b: [UInt8]) throws -> (sessionId: UInt32, K: Int, T: Int, flags: UInt8) {
        guard b.count >= logHeaderLength else { throw ProgressStoreError.truncated }
        guard Array(b[0..<4]) == logMagic else { throw ProgressStoreError.badMagic }
        let version = ByteOps.readUInt16(b, 4)
        guard version == formatVersion else { throw ProgressStoreError.unsupportedVersion(Int(version)) }
        let sessionId = ByteOps.readUInt32(b, 6)
        let K = Int(ByteOps.readUInt24(b, 10))
        let T = Int(ByteOps.readUInt16(b, 13))
        guard K > 0, T > 0 else { throw ProgressStoreError.truncated }
        return (sessionId, K, T, b[15])
    }

    /// 把一份日志重放到已有会话上，返回被自检丢弃的记录数。
    /// 末尾若有崩溃留下的半条记录，直接丢弃而不视为损坏。
    @discardableResult
    static func applyLog(_ data: Data, to session: ReceiveSession) throws -> Int {
        let b = [UInt8](data)
        let head = try logHeader(b)
        // 参数对不上说明日志与会话不是同一份，丢日志保会话
        guard head.K == session.K, head.T == session.T else { throw ProgressStoreError.truncated }

        let parsed = try readRecords(b, from: logHeaderLength, count: nil,
                                     K: head.K, T: head.T, tolerateTruncation: true)
        let dropped = session.decoder.replay(parsed.records)
        if let stats = parsed.stats { session.stats = stats }
        session.tryExtractMeta()
        session.lastSavedAt = Date()
        return dropped
    }

    /// 重放一份日志文件。会话不存在时（只有日志没有 checkpoint）按日志头建出来
    @discardableResult
    private static func replayLog(at url: URL,
                                  into byId: inout [UInt32: ReceiveSession]) throws -> UInt32? {
        let data = try Data(contentsOf: url)
        let head = try logHeader([UInt8](data))

        let session: ReceiveSession
        if let existing = byId[head.sessionId] {
            session = existing
        } else {
            session = ReceiveSession(sessionId: head.sessionId, K: head.K, T: head.T,
                                     codec: (head.flags & 0x04 != 0) ? .peeling : .linearSolve,
                                     compressed: head.flags & 0x01 != 0)
            byId[head.sessionId] = session
        }
        try applyLog(data, to: session)
        return head.sessionId
    }

    static func remove(sessionId: UInt32) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionId))
        try? FileManager.default.removeItem(at: logURL(for: sessionId))
    }

    /// 手动清理入口：删除全部进度文件与日志
    @discardableResult
    static func clearAll() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var n = 0
        for url in items where url.pathExtension == "vdpg" || url.pathExtension == "vdlog" {
            if (try? fm.removeItem(at: url)) != nil { n += 1 }
        }
        return n
    }
}

// MARK: - 增量日志写入器

/// 单会话的增量日志。FileHandle 常开，只做 append，不 atomic 替换、不 fsync——
/// 每次写入量正比于本次新增的成果，与已有进度无关。
final class ProgressJournal {

    let sessionId: UInt32
    private let K: Int
    private let T: Int
    private var handle: FileHandle?
    /// 已写入的日志字节数，压实时机的判据
    private(set) var byteCount: Int = 0

    init(session: ReceiveSession) throws {
        self.sessionId = session.sessionId
        self.K = session.K
        self.T = session.T
        try ProgressStore.ensureDirectory()

        let url = ProgressStore.logURL(for: session.sessionId)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            var header: [UInt8] = []
            header.append(contentsOf: ProgressStore.logMagic)
            ByteOps.appendUInt16(&header, ProgressStore.formatVersion)
            ByteOps.appendUInt32(&header, session.sessionId)
            ByteOps.appendUInt24(&header, UInt32(session.K))
            ByteOps.appendUInt16(&header, UInt16(session.T))
            var flags: UInt8 = 0
            if session.compressed { flags |= 0x01 }
            if session.codec == .peeling { flags |= 0x04 }
            header.append(flags)
            try Data(header).write(to: url, options: .atomic)
        }
        let h = try FileHandle(forWritingTo: url)
        byteCount = Int(try h.seekToEnd())
        handle = h
    }

    /// 追加一批记录与一份统计快照
    func append(_ records: [ProgressRecord], stats: SessionStats) throws {
        guard let handle, !records.isEmpty else { return }
        var bytes = ProgressStore.encodeRecords(records, K: K, T: T)
        ProgressStore.appendStatsRecord(&bytes, stats)
        try handle.write(contentsOf: Data(bytes))
        byteCount += bytes.count
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { try? handle?.close() }
}
