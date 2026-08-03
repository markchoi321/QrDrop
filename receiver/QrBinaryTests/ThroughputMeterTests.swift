//
//  ThroughputMeterTests.swift
//  QrBinaryTests
//
//  接收速率统计的单元测试。时间由参数注入，不依赖真实时钟。
//

import Testing
import Foundation
@testable import QrBinary

@MainActor
struct ThroughputMeterTests {

    @Test func emptyMeterIsZero() {
        let m = ThroughputMeter()
        #expect(m.bytesPerSecond(window: 1, now: 100) == 0)
        #expect(m.bytesPerSecond(window: 5, now: 100) == 0)
    }

    @Test func averagesStrictlyOverWindowWidth() {
        let m = ThroughputMeter()
        m.record(bytes: 1000, now: 100.0)
        m.record(bytes: 1000, now: 100.5)
        // 严格按窗口宽度做除数：1 秒窗口只含 100.5 那笔，5 秒窗口含两笔
        #expect(m.bytesPerSecond(window: 1, now: 101.0) == 1000)
        #expect(m.bytesPerSecond(window: 5, now: 101.0) == 400)
    }

    @Test func oneSecondWindowDropsOldSamplesButFiveSecondKeepsThem() {
        let m = ThroughputMeter()
        m.record(bytes: 1000, now: 100.0)
        m.record(bytes: 1000, now: 100.5)
        // t=105 时两个样本都已超出 1 秒窗口，5 秒窗口只剩 100.5 那笔（100.0 恰好落在边界外）
        #expect(m.bytesPerSecond(window: 1, now: 105.0) == 0)
        #expect(m.bytesPerSecond(window: 5, now: 105.0) == 200)
    }

    @Test func rateDecaysToZeroWhenNothingArrives() {
        let m = ThroughputMeter()
        m.record(bytes: 4096, now: 200.0)
        #expect(m.bytesPerSecond(window: 5, now: 201.0) > 0)
        // 超出最长窗口后必须归零，否则停止扫描后读数会一直挂着
        #expect(m.bytesPerSecond(window: 5, now: 206.0) == 0)
    }

    @Test func startupDoesNotSpike() {
        let m = ThroughputMeter()
        // 刚记录就查询，也只能得到「1 秒内收了 1000 字节」，不得因除以极小时长而虚高
        m.record(bytes: 1000, now: 50.0)
        #expect(m.bytesPerSecond(window: 1, now: 50.0) == 1000)
        #expect(m.bytesPerSecond(window: 5, now: 50.0) == 200)
    }

    @Test func zeroBytesIgnored() {
        let m = ThroughputMeter()
        m.record(bytes: 0, now: 10)
        #expect(m.bytesPerSecond(window: 1, now: 11) == 0)
    }

    @Test func resetClearsEverything() {
        let m = ThroughputMeter()
        m.record(bytes: 8192, now: 300.0)
        m.reset()
        #expect(m.bytesPerSecond(window: 5, now: 300.5) == 0)
    }

    @Test func formatsUnits() {
        #expect(ThroughputMeter.format(0) == "0 B/s")
        #expect(ThroughputMeter.format(512) == "512 B/s")
        #expect(ThroughputMeter.format(2048) == "2.0 KB/s")
        #expect(ThroughputMeter.format(3 * 1024 * 1024) == "3.00 MB/s")
    }

    /// 速率必须只计去重后的新块：采样混叠模型要求每个二维码被扫到 2.5 次以上，
    /// 把重复帧算进去会让读数虚高一倍以上，无法用来比较档位与间隔
    @Test func duplicateBlocksAreNotCounted() throws {
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
        let receiver = FileReceiver()
        receiver.clearAll()
        _ = receiver.processPayload(Data(bytes))
        let after1 = receiver.throughput.bytesPerSecond(window: 5)
        // 同一帧重复投递，blockId 相同，应全部被去重，速率不再增长
        for _ in 0..<4 { _ = receiver.processPayload(Data(bytes)) }
        let after5 = receiver.throughput.bytesPerSecond(window: 5)
        #expect(after1 > 0)
        #expect(after5 == after1, "重复帧不得计入速率")
    }
}
