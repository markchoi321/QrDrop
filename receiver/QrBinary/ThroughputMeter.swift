//
//  ThroughputMeter.swift
//  QrBinary
//
//  接收速率统计：滑动窗口内的字节吞吐。
//

import Foundation
import QuartzCore

/// 按时间窗口统计接收速率。
///
/// 计入的是**去重后**新收到的编码块字节数（块数 × T），不含重复块。
/// 这一点是刻意的：采样混叠模型要求每个二维码被扫到 2.5 次以上
/// （见 receiver/README.md），把重复帧算进去会让速率虚高一倍以上，
/// 无法用来比较不同档位与间隔的实际效果。
@MainActor
final class ThroughputMeter {

    /// 最长统计窗口，超出即丢弃
    private let maxWindow: CFTimeInterval = 5.0

    private var samples: [(at: CFTimeInterval, bytes: Int)] = []

    /// 记录一次新增字节
    func record(bytes: Int, now: CFTimeInterval = CACurrentMediaTime()) {
        guard bytes > 0 else { return }
        samples.append((now, bytes))
        prune(now: now)
    }

    /// 最近 `window` 秒内的平均速率（字节/秒），即窗口内字节数除以窗口宽度。
    ///
    /// 严格按窗口宽度做除数，不按「已运行时长」折算——后者会让读数与
    /// 「最近 N 秒的 Bps」这个名字对不上，开头几秒还会虚高。
    func bytesPerSecond(window: CFTimeInterval, now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard window > 0 else { return 0 }
        prune(now: now)
        let cutoff = now - window
        let total = samples.reduce(0) { $0 + ($1.at > cutoff ? $1.bytes : 0) }
        return total > 0 ? Double(total) / window : 0
    }

    func reset() {
        samples.removeAll()
    }

    private func prune(now: CFTimeInterval) {
        let cutoff = now - maxWindow
        guard let first = samples.first, first.at < cutoff else { return }
        samples.removeAll { $0.at < cutoff }
    }

    /// 速率文案，自动换算单位
    static func format(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1 { return "0 B/s" }
        if bytesPerSecond < 1024 { return String(format: "%.0f B/s", bytesPerSecond) }
        if bytesPerSecond < 1024 * 1024 { return String(format: "%.1f KB/s", bytesPerSecond / 1024) }
        return String(format: "%.2f MB/s", bytesPerSecond / (1024 * 1024))
    }
}
