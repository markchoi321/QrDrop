//
//  ThroughputMeter.swift
//  QrBinary
//
//  滑动窗口计数：接收字节吞吐与识别帧率共用，窗口固定 1 秒。
//

import Foundation
import QuartzCore

/// 按 1 秒滑动窗口统计速率。
///
/// 用于两处：
///   - 接收吞吐：计入的是**去重后**新收到的编码块字节数（块数 × T），不含重复块。
///     这一点是刻意的：采样混叠模型要求每个二维码被扫到 2.5 次以上
///     （见 receiver/README.md），把重复帧算进去会让速率虚高一倍以上，
///     无法用来比较不同档位与间隔的实际效果。
///   - 识别帧率：每帧记 1，`perSecond` 即 fps。
///
/// 窗口宽度固定为 1 秒，不做可选窗口：多档窗口只是同一条曲线的不同平滑程度，
/// 并排显示占地方又难解读，读数抖动看 1 秒的即可。
///
/// 相机的送检与命中计数发生在采集队列上，因此内部加锁而不做 actor 隔离。
final class ThroughputMeter: @unchecked Sendable {

    /// 统计窗口宽度，超出即丢弃
    static let window: CFTimeInterval = 1.0

    private let lock = NSLock()
    private var samples: [(at: CFTimeInterval, count: Int)] = []

    /// 记录一次事件。`count` 默认 1，用于帧计数；传字节数则用于吞吐统计。
    func record(bytes count: Int = 1, now: CFTimeInterval = CACurrentMediaTime()) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        samples.append((now, count))
        prune(now: now)
    }

    /// 最近 1 秒的平均速率（计数/秒），即窗口内总数除以窗口宽度。
    ///
    /// 严格按窗口宽度做除数，不按「已运行时长」折算——后者会让读数与
    /// 「最近 1 秒的速率」这个名字对不上，开头几秒还会虚高。
    func perSecond(now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        lock.lock()
        defer { lock.unlock() }
        prune(now: now)
        let total = samples.reduce(0) { $0 + $1.count }
        return Double(total) / ThroughputMeter.window
    }

    /// 吞吐语义的别名，读数含义为字节/秒
    func bytesPerSecond(now: CFTimeInterval = CACurrentMediaTime()) -> Double {
        perSecond(now: now)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
    }

    /// 丢弃窗口外的样本。调用方必须已持锁。
    private func prune(now: CFTimeInterval) {
        let cutoff = now - ThroughputMeter.window
        guard let first = samples.first, first.at <= cutoff else { return }
        samples.removeAll { $0.at <= cutoff }
    }

    /// 速率文案，自动换算单位
    static func format(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1 { return "0 B/s" }
        if bytesPerSecond < 1024 { return String(format: "%.0f B/s", bytesPerSecond) }
        if bytesPerSecond < 1024 * 1024 { return String(format: "%.1f KB/s", bytesPerSecond / 1024) }
        return String(format: "%.2f MB/s", bytesPerSecond / (1024 * 1024))
    }

    /// 帧率文案
    static func formatFps(_ fps: Double) -> String {
        String(format: "%.1f", fps)
    }
}
