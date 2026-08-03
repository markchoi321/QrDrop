//
//  BitSet.swift
//  QrDrop
//
//  定长位集，承载 RLNC 的 K 位系数向量。
//  以 UInt64 为字，异或按字批量进行，避免逐位操作。
//

import Foundation

struct BitSet {
    /// 位数（等于 K）
    let bitCount: Int
    /// 底层字数组，低位字在前
    private(set) var words: [UInt64]

    init(bitCount: Int) {
        self.bitCount = bitCount
        self.words = [UInt64](repeating: 0, count: (bitCount + 63) / 64)
    }

    /// 用 32 位字序列填充：第 i 个 32 位字覆盖位区间 [32i, 32i+32)
    init(bitCount: Int, words32: [UInt32]) {
        self.init(bitCount: bitCount)
        for (i, w) in words32.enumerated() {
            let bit = i * 32
            guard bit < bitCount else { break }
            words[bit >> 6] |= UInt64(w) << UInt64(bit & 63)
        }
        maskTail()
    }

    /// 清掉超出 bitCount 的高位
    private mutating func maskTail() {
        let rem = bitCount & 63
        if rem != 0, let last = words.indices.last {
            words[last] &= (UInt64(1) << UInt64(rem)) - 1
        }
    }

    var isZero: Bool {
        for w in words where w != 0 { return false }
        return true
    }

    /// 最高置位的下标；全零返回 nil
    var highestBit: Int? {
        var i = words.count - 1
        while i >= 0 {
            let w = words[i]
            if w != 0 { return i * 64 + (63 - w.leadingZeroBitCount) }
            i -= 1
        }
        return nil
    }

    @inline(__always)
    func contains(_ bit: Int) -> Bool {
        (words[bit >> 6] >> UInt64(bit & 63)) & 1 == 1
    }

    @inline(__always)
    mutating func set(_ bit: Int) {
        words[bit >> 6] |= UInt64(1) << UInt64(bit & 63)
    }

    @inline(__always)
    mutating func clear(_ bit: Int) {
        words[bit >> 6] &= ~(UInt64(1) << UInt64(bit & 63))
    }

    mutating func xor(_ other: BitSet) {
        for i in 0..<words.count { words[i] ^= other.words[i] }
    }

    /// 升序返回全部置位下标
    var indices: [Int] {
        var out: [Int] = []
        for (i, w0) in words.enumerated() {
            var w = w0
            while w != 0 {
                let t = w.trailingZeroBitCount
                out.append(i * 64 + t)
                w &= w - 1
            }
        }
        return out
    }

    /// 小端序列化，长度 ceil(bitCount/8)，仅用于测试向量比对
    var littleEndianBytes: [UInt8] {
        let n = (bitCount + 7) / 8
        var out = [UInt8](repeating: 0, count: n)
        for j in 0..<n {
            out[j] = UInt8((words[j >> 3] >> UInt64((j & 7) * 8)) & 0xFF)
        }
        return out
    }
}
