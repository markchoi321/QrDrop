//
//  ByteOps.swift
//  QrDrop
//
//  字节级公共工具：批量异或、大端读写、CRC32。
//  异或按 8 字节字批量进行，避免逐字节访问（Data 的 subscript 尤其慢）。
//

import Foundation
import zlib

enum ByteOps {

    /// dst ^= src，两者长度必须相等
    @inline(__always)
    static func xorInPlace(_ dst: inout [UInt8], _ src: [UInt8]) {
        let n = min(dst.count, src.count)
        dst.withUnsafeMutableBytes { dRaw in
            src.withUnsafeBytes { sRaw in
                let wordCount = n / 8
                let dw = dRaw.bindMemory(to: UInt64.self)
                let sw = sRaw.bindMemory(to: UInt64.self)
                for i in 0..<wordCount { dw[i] ^= sw[i] }
                // 尾部不足 8 字节的部分直接按原始字节处理，避免重复绑定内存类型
                var i = wordCount * 8
                while i < n { dRaw[i] ^= sRaw[i]; i += 1 }
            }
        }
    }

    /// dst ^= src 的切片版本，用于直接吃帧体里的块
    @inline(__always)
    static func xorInPlace(_ dst: inout [UInt8], _ src: ArraySlice<UInt8>) {
        let n = min(dst.count, src.count)
        dst.withUnsafeMutableBytes { dRaw in
            src.withUnsafeBytes { sRaw in
                let wordCount = n / 8
                let dw = dRaw.bindMemory(to: UInt64.self)
                let sw = sRaw.bindMemory(to: UInt64.self)
                for i in 0..<wordCount { dw[i] ^= sw[i] }
                // 尾部不足 8 字节的部分直接按原始字节处理，避免重复绑定内存类型
                var i = wordCount * 8
                while i < n { dRaw[i] ^= sRaw[i]; i += 1 }
            }
        }
    }

    /// zlib 标准 IEEE CRC32
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        guard !bytes.isEmpty else { return UInt32(zlib.crc32(0, nil, 0)) }
        return bytes.withUnsafeBufferPointer { buf in
            UInt32(truncatingIfNeeded: zlib.crc32(0, buf.baseAddress, uInt(buf.count)))
        }
    }

    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        guard !bytes.isEmpty else { return UInt32(zlib.crc32(0, nil, 0)) }
        return bytes.withUnsafeBufferPointer { buf in
            UInt32(truncatingIfNeeded: zlib.crc32(0, buf.baseAddress, uInt(buf.count)))
        }
    }

    // MARK: - 大端读写

    @inline(__always)
    static func readUInt16(_ b: [UInt8], _ o: Int) -> UInt16 {
        (UInt16(b[o]) << 8) | UInt16(b[o + 1])
    }

    @inline(__always)
    static func readUInt24(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 16) | (UInt32(b[o + 1]) << 8) | UInt32(b[o + 2])
    }

    @inline(__always)
    static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    @inline(__always)
    static func readUInt64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[o + i]) }
        return v
    }

    static func appendUInt16(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v))
    }

    static func appendUInt24(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8(truncatingIfNeeded: v >> 16))
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v))
    }

    static func appendUInt32(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8(truncatingIfNeeded: v >> 24))
        out.append(UInt8(truncatingIfNeeded: v >> 16))
        out.append(UInt8(truncatingIfNeeded: v >> 8))
        out.append(UInt8(truncatingIfNeeded: v))
    }

    static func appendUInt64(_ out: inout [UInt8], _ v: UInt64) {
        for i in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: v >> UInt64(i)))
        }
    }

    static func appendDouble(_ out: inout [UInt8], _ v: Double) {
        appendUInt64(&out, v.bitPattern)
    }

    @inline(__always)
    static func readDouble(_ b: [UInt8], _ o: Int) -> Double {
        Double(bitPattern: readUInt64(b, o))
    }
}
