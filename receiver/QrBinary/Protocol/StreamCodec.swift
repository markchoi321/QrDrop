//
//  StreamCodec.swift
//  QrBinary
//
//  L4 流层：StreamHeader 解析 / 组装 + raw deflate 压缩。
//  严格对应 CONTRACT.md 第 6 节。压缩无 zlib/gzip 容器，windowBits 取 -15。
//

import Foundation
import CryptoKit
import zlib

/// 流元数据，解出块 0 后填充
struct StreamMeta: Sendable {
    let fileName: String
    let originalSize: UInt64
    let payloadSize: UInt64
    let sha256: [UInt8]
    let compressed: Bool
    /// 头部原始字节，持久化时原样落盘
    let rawHeader: [UInt8]

    var headerLength: Int { rawHeader.count }
}

enum StreamError: Error, LocalizedError {
    case badMagic
    case unsupportedVersion(Int)
    case truncated
    case badFileName
    case inflateFailed(Int32)
    case deflateFailed(Int32)
    case digestMismatch
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badMagic: return "流头 magic 不匹配"
        case .unsupportedVersion(let v): return "流格式版本不支持: \(v)"
        case .truncated: return "流数据长度不足"
        case .badFileName: return "文件名不是合法 UTF-8"
        case .inflateFailed(let c): return "解压失败，zlib 返回 \(c)"
        case .deflateFailed(let c): return "压缩失败，zlib 返回 \(c)"
        case .cancelled: return "合并已中止"
        case .digestMismatch: return "SHA-256 校验失败"
        }
    }
}

enum StreamCodec {

    static let magic: [UInt8] = [0x56, 0x44]     // "VD"
    static let version: UInt8 = 1
    static let headerFixedLength = 54

    // MARK: - 解析

    /// 只解析头部。数据不足以容纳完整头部时返回 nil（还没解出足够的源块）。
    static func parseHeader(_ bytes: [UInt8]) throws -> StreamMeta? {
        guard bytes.count >= headerFixedLength else { return nil }
        guard bytes[0] == magic[0], bytes[1] == magic[1] else { throw StreamError.badMagic }
        guard bytes[2] == version else { throw StreamError.unsupportedVersion(Int(bytes[2])) }

        let compressed = (bytes[3] & 1) == 1
        let originalSize = ByteOps.readUInt64(bytes, 4)
        let payloadSize = ByteOps.readUInt64(bytes, 12)
        let digest = Array(bytes[20..<52])
        let nameLen = Int(ByteOps.readUInt16(bytes, 52))
        let total = headerFixedLength + nameLen
        guard bytes.count >= total else { return nil }
        guard let name = String(bytes: bytes[headerFixedLength..<total], encoding: .utf8) else {
            throw StreamError.badFileName
        }
        return StreamMeta(fileName: name,
                          originalSize: originalSize,
                          payloadSize: payloadSize,
                          sha256: digest,
                          compressed: compressed,
                          rawHeader: Array(bytes[0..<total]))
    }

    /// 解析整条流，返回元数据与还原后的原始文件内容（已按 flag 解压）
    static func parseStream(_ bytes: [UInt8]) throws -> (meta: StreamMeta, content: [UInt8]) {
        guard let meta = try parseHeader(bytes) else { throw StreamError.truncated }
        let start = meta.headerLength
        let end = start + Int(meta.payloadSize)
        guard end <= bytes.count else { throw StreamError.truncated }
        let body = Array(bytes[start..<end])
        let content = meta.compressed ? try inflateRaw(body) : body
        return (meta, content)
    }

    // MARK: - 组装（测试往返用）

    static func buildStream(content: [UInt8], fileName: String, allowCompress: Bool = true) throws -> (stream: [UInt8], compressed: Bool) {
        let digest = sha256(content)
        var payload = content
        var compressed = false
        if allowCompress {
            let packed = try deflateRaw(content)
            // 压缩不变小则关闭：jpg/png/zip/mp4 上 deflate 会让数据变大
            if packed.count < content.count {
                payload = packed
                compressed = true
            }
        }
        let nameBytes = Array(fileName.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(headerFixedLength + nameBytes.count + payload.count)
        out.append(contentsOf: magic)
        out.append(version)
        out.append(compressed ? 1 : 0)
        ByteOps.appendUInt64(&out, UInt64(content.count))
        ByteOps.appendUInt64(&out, UInt64(payload.count))
        out.append(contentsOf: digest)
        ByteOps.appendUInt16(&out, UInt16(nameBytes.count))
        out.append(contentsOf: nameBytes)
        out.append(contentsOf: payload)
        return (out, compressed)
    }

    // MARK: - SHA-256

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(CryptoKit.SHA256.hash(data: bytes))
    }

    // MARK: - raw deflate

    /// windowBits = -15 表示无容器的 raw deflate
    static func inflateRaw(_ input: [UInt8]) throws -> [UInt8] {
        if input.isEmpty { return [] }
        var strm = z_stream()
        var rc = inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw StreamError.inflateFailed(rc) }
        defer { inflateEnd(&strm) }

        var out = [UInt8]()
        out.reserveCapacity(input.count * 4 + 1024)
        let chunkSize = 65536
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var source = input

        try source.withUnsafeMutableBufferPointer { src in
            strm.next_in = src.baseAddress
            strm.avail_in = uInt(src.count)
            repeat {
                let produced: Int = try chunk.withUnsafeMutableBufferPointer { dst -> Int in
                    strm.next_out = dst.baseAddress
                    strm.avail_out = uInt(chunkSize)
                    rc = inflate(&strm, Z_NO_FLUSH)
                    if rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR {
                        throw StreamError.inflateFailed(rc)
                    }
                    return chunkSize - Int(strm.avail_out)
                }
                if produced > 0 { out.append(contentsOf: chunk[0..<produced]) }
                if rc == Z_STREAM_END { break }
                if produced == 0 && strm.avail_in == 0 { break }
            } while true
        }
        return out
    }

    static func deflateRaw(_ input: [UInt8]) throws -> [UInt8] {
        var strm = z_stream()
        var rc = deflateInit2_(&strm, Z_BEST_COMPRESSION, Z_DEFLATED, -15, 8,
                               Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw StreamError.deflateFailed(rc) }
        defer { deflateEnd(&strm) }

        var out = [UInt8]()
        let chunkSize = 65536
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        // 空输入时数组的 baseAddress 为 nil，补一个占位字节但 avail_in 仍为 0
        var source = input.isEmpty ? [UInt8](repeating: 0, count: 1) : input
        let availIn = uInt(input.count)

        try source.withUnsafeMutableBufferPointer { src in
            strm.next_in = src.baseAddress
            strm.avail_in = availIn
            repeat {
                let produced: Int = try chunk.withUnsafeMutableBufferPointer { dst -> Int in
                    strm.next_out = dst.baseAddress
                    strm.avail_out = uInt(chunkSize)
                    rc = deflate(&strm, Z_FINISH)
                    if rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR {
                        throw StreamError.deflateFailed(rc)
                    }
                    return chunkSize - Int(strm.avail_out)
                }
                if produced > 0 { out.append(contentsOf: chunk[0..<produced]) }
                if rc == Z_STREAM_END { break }
            } while true
        }
        return out
    }
}
