//
//  ThroughputMeterTests.swift
//  QrDropTests
//
//  接收速率与识别帧率统计的单元测试。时间由参数注入，不依赖真实时钟。
//

import Testing
import Foundation
import QuartzCore
@testable import QrDrop

@MainActor
struct ThroughputMeterTests {

    @Test func emptyMeterIsZero() {
        let m = ThroughputMeter()
        #expect(m.bytesPerSecond(now: 100) == 0)
    }

    @Test func averagesStrictlyOverWindowWidth() {
        let m = ThroughputMeter()
        m.record(bytes: 1000, now: 100.0)
        m.record(bytes: 1000, now: 100.5)
        // 查询会顺带丢弃窗口外的样本，因此断言必须按时间递增排列，不能倒着查
        // 两笔都在窗口内时按窗口宽度 1 秒做除数
        #expect(m.bytesPerSecond(now: 100.6) == 2000)
        // 窗口是 (now-1, now]，t=101.0 时 100.0 那笔恰好落在窗口外
        #expect(m.bytesPerSecond(now: 101.0) == 1000)
    }

    @Test func rateDecaysToZeroWhenNothingArrives() {
        let m = ThroughputMeter()
        m.record(bytes: 4096, now: 200.0)
        #expect(m.bytesPerSecond(now: 200.5) > 0)
        // 超出窗口后必须归零，否则停止扫描后读数会一直挂着
        #expect(m.bytesPerSecond(now: 201.5) == 0)
    }

    @Test func startupDoesNotSpike() {
        let m = ThroughputMeter()
        // 刚记录就查询，也只能得到「1 秒内收了 1000 字节」，不得因除以极小时长而虚高
        m.record(bytes: 1000, now: 50.0)
        #expect(m.bytesPerSecond(now: 50.0) == 1000)
    }

    @Test func zeroBytesIgnored() {
        let m = ThroughputMeter()
        m.record(bytes: 0, now: 10)
        #expect(m.bytesPerSecond(now: 10.5) == 0)
    }

    @Test func resetClearsEverything() {
        let m = ThroughputMeter()
        m.record(bytes: 8192, now: 300.0)
        m.reset()
        #expect(m.bytesPerSecond(now: 300.5) == 0)
    }

    /// 帧计数语义：每帧记 1，perSecond 即 fps
    @Test func countsFramesAsFps() {
        let m = ThroughputMeter()
        // 1 秒内均匀记 20 帧
        for i in 0..<20 { m.record(now: 100.0 + Double(i) * 0.05) }
        // 全部 20 帧都在窗口内时读数为 20
        #expect(m.perSecond(now: 100.95) == 20)
        // 窗口 (100.0, 101.0] 只收下 100.05…100.95 这 19 帧
        #expect(m.perSecond(now: 101.0) == 19)
    }

    /// 停止扫描后帧率必须归零，不能一直挂着上次的读数
    @Test func fpsDecaysToZero() {
        let m = ThroughputMeter()
        for i in 0..<10 { m.record(now: 50.0 + Double(i) * 0.1) }
        #expect(m.perSecond(now: 50.9) > 0)
        #expect(m.perSecond(now: 52.0) == 0)
    }

    @Test func formatsFps() {
        #expect(ThroughputMeter.formatFps(0) == "0.0")
        #expect(ThroughputMeter.formatFps(19.96) == "20.0")
    }

    @Test func formatsUnits() {
        #expect(ThroughputMeter.format(0) == "0 B/s")
        #expect(ThroughputMeter.format(512) == "512 B/s")
        #expect(ThroughputMeter.format(2048) == "2.0 KB/s")
        #expect(ThroughputMeter.format(3 * 1024 * 1024) == "3.00 MB/s")
    }

    /// 速率必须只计去重后的新块：采样混叠模型要求每个二维码被扫到 2.5 次以上，
    /// 把重复帧算进去会让读数虚高一倍以上，无法用来比较档位与间隔
    @Test func duplicateBlocksAreNotCounted() async throws {
        let stream = try Vectors.binary("stream.bin")
        let e2e = try Vectors.keyValues("e2e.txt")
        let T = Int(e2e["rlnc.T"]!)!, K = Int(e2e["rlnc.K"]!)!
        let sid = UInt32(e2e["rlnc.sessionId"]!, radix: 16)!
        let m = 8
        let src = TestEncoder.splitSourceBlocks(stream, K: K, T: T)
        let bytes = TestEncoder.encodeFrame(src: src, K: K, T: T, codec: .linearSolve,
                                            compressed: false, sessionId: sid,
                                            baseBlockId: 0, m: m,
                                            composer: LinearSolveComposer(K: K))
        // clearAll 会清空全局共享的进度目录，必须与其它碰盘用例串行
        try await ProgressDiskLock.withLock {
            let engine = DecodeEngine()
            await engine.clearAll()
            await engine.processPayload(Data(bytes))
            // 读数锚定在投喂那一刻。取墙钟的话，后面几次投递一慢就跨过 1 秒窗口边界，
            // 已记的样本被剔掉，断言变成看机器负载的运气。
            // 窗口外的样本才会被剔除，晚于 fedAt 记入的样本仍会计入总量，
            // 所以这个读数照样能验证「重复帧没被计进去」
            let fedAt = CACurrentMediaTime()
            // 同一帧重复投递，blockId 相同，应全部被去重，速率不再增长
            for _ in 0..<4 { await engine.processPayload(Data(bytes)) }
            let after5 = engine.throughput.bytesPerSecond(now: fedAt)
            #expect(after5 > 0)
            #expect(after5 == Double(m * T) / ThroughputMeter.window, "重复帧不得计入速率")
        }
    }
}
