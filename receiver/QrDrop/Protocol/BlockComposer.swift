//
//  BlockComposer.swift
//  QrDrop
//
//  编码块组成推导：blockId -> 参与异或的源块索引集合。
//  对应 CONTRACT.md 第 3.1 节（解方程 / RLNC）与第 4.3 节（剥洋葱 / LT）。
//

import Foundation

/// 编码方案，由帧头 flags 的 codec 位指示
enum Codec: UInt8, Sendable {
    case linearSolve = 0    // 解方程方案（RLNC），增量高斯消元
    case peeling = 1        // 剥洋葱方案（LT），BP 剥离解码

    var displayName: String {
        self == .linearSolve ? "解方程" : "剥洋葱"
    }
}

protocol BlockComposer {
    var K: Int { get }
    func neighborsOf(_ blockId: UInt32) -> [Int]
}

// MARK: - 解方程方案

struct LinearSolveComposer: BlockComposer {
    let K: Int

    /// 由编码块序号推导 K 位系数向量。每个 32 位字独立经 mix32 混淆，
    /// 严禁改用 xorshift32 连续输出拼接（GF(2) 线性变换会让秩停在 32）。
    func coefficients(_ blockId: UInt32) -> BitSet {
        let base = Prng.mix32(blockId)
        let wordCount = (K + 31) / 32
        var words32 = [UInt32](repeating: 0, count: wordCount)
        for i in 0..<wordCount {
            words32[i] = Prng.mix32(base ^ (UInt32(truncatingIfNeeded: i) &* 0x9E37_79B9))
        }
        var bits = BitSet(bitCount: K, words32: words32)
        // 全零兜底：全零块不携带信息，K 很小时出现概率不可忽略，两端规则必须一致
        if bits.isZero {
            bits.set(Int(blockId % UInt32(K)))
        }
        return bits
    }

    func neighborsOf(_ blockId: UInt32) -> [Int] {
        coefficients(blockId).indices
    }
}

// MARK: - 剥洋葱方案

struct PeelingComposer: BlockComposer {
    let K: Int
    let soliton: RobustSoliton

    init(K: Int, soliton: RobustSoliton? = nil) {
        self.K = K
        self.soliton = soliton ?? RobustSoliton(K: K)
    }

    /// 先按 Robust Soliton 抽度数，再用拒绝采样抽 d 个互异索引，升序返回
    func neighborsOf(_ blockId: UInt32) -> [Int] {
        var state = Prng.mix32(blockId)
        let sampled = soliton.sampleDegree(state: state)
        state = sampled.state
        let d = min(sampled.degree, K)

        var picked = Set<Int>()
        picked.reserveCapacity(d)
        let kk = UInt32(K)
        while picked.count < d {
            state = Prng.xorshift32(state)
            picked.insert(Int(state % kk))
        }
        return picked.sorted()
    }
}
