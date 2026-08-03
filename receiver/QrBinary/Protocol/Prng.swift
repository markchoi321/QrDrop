//
//  Prng.swift
//  QrBinary
//
//  跨语言确定性伪随机数发生器。严格对应 protocol/CONTRACT.md 第 2 节。
//  禁止替换为任何语言内置 RNG，两端必须逐位一致。
//

import Foundation

enum Prng {

    /// lowbias32 finalizer。用于把 blockId 混淆成种子。
    @inline(__always)
    static func mix32(_ x0: UInt32) -> UInt32 {
        var x = x0
        x ^= x >> 16
        x = x &* 0x7FEB_352D
        x ^= x >> 15
        x = x &* 0x846C_A68B
        x ^= x >> 16
        return x
    }

    /// xorshift32 状态推进。0 是不动点，调用方需保证种子非零。
    @inline(__always)
    static func xorshift32(_ s0: UInt32) -> UInt32 {
        var s = s0
        s ^= s &<< 13
        s ^= s >> 17
        s ^= s &<< 5
        return s
    }
}
