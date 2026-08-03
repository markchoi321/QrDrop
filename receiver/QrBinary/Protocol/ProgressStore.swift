//
//  ProgressStore.swift
//  QrBinary
//
//  进度持久化。严格对应 CONTRACT.md 第 11 节的二进制格式（全大端，不用 JSON）。
//  位置：Documents/progress/<sessionId 8位小写hex>.vdpg，每会话一个文件。
//

import Foundation

enum ProgressStoreError: Error, LocalizedError {
    case badMagic
    case unsupportedVersion(Int)
    case truncated

    var errorDescription: String? {
        switch self {
        case .badMagic: return "进度文件 magic 不匹配"
        case .unsupportedVersion(let v): return "进度文件版本不支持: \(v)"
        case .truncated: return "进度文件被截断"
        }
    }
}

enum ProgressStore {

    static let magic: [UInt8] = [0x56, 0x44, 0x50, 0x47]     // "VDPG"
    static let formatVersion: UInt16 = 1
    static let statsLength = 40

    // MARK: - 目录

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("progress", isDirectory: true)
    }

    static func fileURL(for sessionId: UInt32) -> URL {
        directory.appendingPathComponent("\(SessionId.hex(sessionId)).vdpg")
    }

    private static func ensureDirectory() throws {
        let dir = directory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - 编码

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

        var flags: UInt8 = 0
        if s.compressed { flags |= 0x01 }
        if s.meta != nil { flags |= 0x02 }
        if s.codec == .peeling { flags |= 0x04 }
        out.append(flags)

        let metaBytes = s.meta?.rawHeader ?? []
        ByteOps.appendUInt16(&out, UInt16(metaBytes.count))
        out.append(contentsOf: metaBytes)

        let solved = s.decoder.snapshotSolved()
        ByteOps.appendUInt32(&out, UInt32(solved.count))
        for rec in solved {
            ByteOps.appendUInt24(&out, UInt32(rec.index))
            out.append(contentsOf: rec.data)
        }

        let pending = s.decoder.snapshotPending()
        ByteOps.appendUInt32(&out, UInt32(pending.count))
        for rec in pending {
            ByteOps.appendUInt32(&out, rec.blockId)
            ByteOps.appendUInt16(&out, UInt16(rec.neighbors.count))
            for i in rec.neighbors { ByteOps.appendUInt24(&out, UInt32(i)) }
            out.append(contentsOf: rec.payload)
        }

        ByteOps.appendUInt32(&out, UInt32(s.stats.framesAccepted))
        ByteOps.appendUInt32(&out, UInt32(s.stats.framesRejected))
        ByteOps.appendUInt32(&out, UInt32(s.stats.blocksReceived))
        ByteOps.appendUInt32(&out, UInt32(s.stats.blocksDuplicate))
        ByteOps.appendUInt32(&out, s.stats.maxBlockId)
        ByteOps.appendUInt32(&out, 0)                                   // reserved
        ByteOps.appendDouble(&out, s.stats.firstSeenAt.timeIntervalSince1970)
        ByteOps.appendDouble(&out, s.stats.lastSeenAt.timeIntervalSince1970)
    }

    // MARK: - 解码

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

        try need(4)
        let solvedCount = Int(ByteOps.readUInt32(b, off)); off += 4
        var solved: [SolvedRecord] = []
        solved.reserveCapacity(solvedCount)
        for _ in 0..<solvedCount {
            try need(3 + T)
            let idx = Int(ByteOps.readUInt24(b, off)); off += 3
            solved.append(SolvedRecord(index: idx, data: Array(b[off..<(off + T)])))
            off += T
        }

        try need(4)
        let pendingCount = Int(ByteOps.readUInt32(b, off)); off += 4
        var pending: [PendingRecord] = []
        pending.reserveCapacity(pendingCount)
        for _ in 0..<pendingCount {
            try need(6)
            let blockId = ByteOps.readUInt32(b, off); off += 4
            let degree = Int(ByteOps.readUInt16(b, off)); off += 2
            try need(degree * 3 + T)
            var neighbors: [Int] = []
            neighbors.reserveCapacity(degree)
            for _ in 0..<degree {
                neighbors.append(Int(ByteOps.readUInt24(b, off))); off += 3
            }
            pending.append(PendingRecord(blockId: blockId, neighbors: neighbors,
                                         payload: Array(b[off..<(off + T)])))
            off += T
        }

        try need(statsLength)
        var stats = SessionStats()
        stats.framesAccepted = Int(ByteOps.readUInt32(b, off))
        stats.framesRejected = Int(ByteOps.readUInt32(b, off + 4))
        stats.blocksReceived = Int(ByteOps.readUInt32(b, off + 8))
        stats.blocksDuplicate = Int(ByteOps.readUInt32(b, off + 12))
        stats.maxBlockId = ByteOps.readUInt32(b, off + 16)
        stats.firstSeenAt = Date(timeIntervalSince1970: ByteOps.readDouble(b, off + 24))
        stats.lastSeenAt = Date(timeIntervalSince1970: ByteOps.readDouble(b, off + 32))
        off += statsLength

        let session = ReceiveSession(sessionId: sessionId, K: K, T: T,
                                     codec: codec, compressed: compressed, stats: stats)
        session.meta = meta
        session.decoder.restore(solved: solved, pending: pending)
        session.lastSavedAt = Date()
        return (session, off)
    }

    // MARK: - 磁盘读写

    static func save(_ session: ReceiveSession) throws {
        try ensureDirectory()
        let data = encode([session])
        try data.write(to: fileURL(for: session.sessionId), options: .atomic)
        session.lastSavedAt = Date()
    }

    /// App 启动时扫描目录恢复全部会话
    static func loadAll() -> (sessions: [ReceiveSession], failures: [String]) {
        var sessions: [ReceiveSession] = []
        var failures: [String] = []
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        for url in items where url.pathExtension == "vdpg" {
            do {
                let data = try Data(contentsOf: url)
                sessions.append(contentsOf: try decode(data))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (sessions, failures)
    }

    static func remove(sessionId: UInt32) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionId))
    }

    /// 手动清理入口：删除全部进度文件
    @discardableResult
    static func clearAll() -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var n = 0
        for url in items where url.pathExtension == "vdpg" {
            if (try? fm.removeItem(at: url)) != nil { n += 1 }
        }
        return n
    }
}
