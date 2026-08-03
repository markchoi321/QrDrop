//
//  FrameParser.swift
//  QrDrop
//
//  L2 帧层：20 字节帧头解析 + 长度校验 + CRC32 校验。
//  严格对应 CONTRACT.md 第 8 节。校验顺序固定，任一失败整帧丢弃。
//

import Foundation

struct ParsedFrame {
    let sessionId: UInt32
    let K: Int
    let T: Int
    let m: Int
    let codec: Codec
    let compressed: Bool
    let baseBlockId: UInt32
    /// 帧体，长度恒为 m × T
    let body: [UInt8]

    /// 第 i 个编码块的序号（uint32 回绕）
    @inline(__always)
    func blockId(_ i: Int) -> UInt32 {
        baseBlockId &+ UInt32(truncatingIfNeeded: i)
    }

    /// 第 i 个编码块的载荷切片
    @inline(__always)
    func block(_ i: Int) -> ArraySlice<UInt8> {
        body[(i * T)..<((i + 1) * T)]
    }
}

enum FrameParser {

    static let magic: UInt8 = 0x56
    static let protocolVersion: UInt8 = 1
    static let headerLength = 20

    /// 校验顺序：长度 ≥ 20 → magic → 协议版本 → 长度等于 20 + m×T → CRC32
    static func parse(_ bytes: [UInt8]) -> ParsedFrame? {
        guard bytes.count >= headerLength else { return nil }
        guard bytes[0] == magic else { return nil }

        let flags = bytes[1]
        guard (flags >> 4) == protocolVersion else { return nil }
        let compressed = (flags >> 3) & 1 == 1
        let codec = Codec(rawValue: (flags >> 2) & 1) ?? .linearSolve

        let sessionId = ByteOps.readUInt32(bytes, 2)
        let K = Int(ByteOps.readUInt24(bytes, 6))
        let T = Int(ByteOps.readUInt16(bytes, 9))
        let m = Int(bytes[11])
        let baseBlockId = ByteOps.readUInt32(bytes, 12)
        let crc = ByteOps.readUInt32(bytes, 16)

        guard K > 0, T > 0, m > 0 else { return nil }
        guard bytes.count == headerLength + m * T else { return nil }

        let body = Array(bytes[headerLength...])
        guard ByteOps.crc32(body) == crc else { return nil }

        return ParsedFrame(sessionId: sessionId, K: K, T: T, m: m,
                           codec: codec, compressed: compressed,
                           baseBlockId: baseBlockId, body: body)
    }
}
