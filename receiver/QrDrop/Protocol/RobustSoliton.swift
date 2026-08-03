//
//  RobustSoliton.swift
//  QrDrop
//
//  Robust Soliton 度分布与量化 CDF。严格对应 CONTRACT.md 第 4.1 / 4.2 节。
//  ln 结果量化到 2^-16 网格，避免跨平台 libm 的 ulp 差异传导到度数抽样。
//

import Foundation

struct RobustSoliton {

    static let defaultC = 0.03
    static let defaultDelta = 0.05
    private static let lnGrid = 65536.0
    /// 2^32，超出 UInt32 范围，故 CDF 用 UInt64 存
    static let cdfTop: UInt64 = 4_294_967_296

    let K: Int
    /// 长度 K+1，下标 0 不用；cdf[K] 恒为 2^32
    let cdf: [UInt64]

    /// 量化对数：floor(ln(x) * 65536 + 0.5) / 65536
    @inline(__always)
    static func lnq(_ x: Double) -> Double {
        (Foundation.log(x) * lnGrid + 0.5).rounded(.down) / lnGrid
    }

    init(K: Int, c: Double = RobustSoliton.defaultC, delta: Double = RobustSoliton.defaultDelta) {
        self.K = K
        let kd = Double(K)

        var rho = [Double](repeating: 0, count: K + 2)
        rho[1] = 1.0 / kd
        if K >= 2 {
            for d in 2...K {
                rho[d] = 1.0 / (Double(d) * Double(d - 1))
            }
        }

        let R = c * RobustSoliton.lnq(kd / delta) * kd.squareRoot()
        var tau = [Double](repeating: 0, count: K + 2)
        let kr = max(1, Int(kd / R))
        // 注意上界：与参考实现的 range(1, min(kr, K+1)) 一致，取不到上界本身
        let upper = min(kr, K + 1)
        if upper > 1 {
            for d in 1..<upper { tau[d] = R / (Double(d) * kd) }
        }
        if kr <= K {
            tau[kr] = max(0.0, R * RobustSoliton.lnq(R / delta) / kd)
        }

        // 归一化因子必须按 d 升序累加，顺序影响浮点结果
        var Z = 0.0
        for d in 1...K { Z += rho[d] + tau[d] }

        var table = [UInt64](repeating: 0, count: K + 1)
        var acc = 0.0
        for d in 1...K {
            acc += (rho[d] + tau[d]) / Z
            let v = acc * 4_294_967_296.0
            table[d] = v >= 4_294_967_296.0 ? RobustSoliton.cdfTop : UInt64(v)
        }
        table[K] = RobustSoliton.cdfTop      // 末档兜底，保证一定命中
        self.cdf = table
    }

    /// 抽度数：推进状态后在 CDF 上二分，返回 (度数, 新状态)
    @inline(__always)
    func sampleDegree(state: UInt32) -> (degree: Int, state: UInt32) {
        let s = Prng.xorshift32(state)
        let r = UInt64(s)
        var lo = 1
        var hi = K
        while lo < hi {
            let mid = (lo + hi) / 2
            if cdf[mid] <= r { lo = mid + 1 } else { hi = mid }
        }
        return (lo, s)
    }
}
