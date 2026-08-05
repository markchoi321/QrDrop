//
//  CompletionProfileTests.swift
//  QrDropTests
//
//  收齐那一刻的耗时剖析。按真实规模跑，默认跳过（很慢），需要显式打开：
//      QRDROP_PROFILE=1 xcodebuild test -only-testing:QrDropTests/CompletionProfileTests …
//
//  5 MB 文件经发送端选参得到 LT / T=293 / K≈17894 / m=10，因此这里照此构造。
//

import Testing
import Foundation
import QuartzCore
@testable import QrDrop

@MainActor
struct CompletionProfileTests {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["QRDROP_PROFILE"] != nil
    }

    @Test func completionMomentProfile() async throws {
        guard enabled else { return }
        try await ProgressDiskLock.withLock { try profile(contentSize: 5 * 1024 * 1024, T: 293, m: 10) }
    }

    /// 给界面手工验收造一份半截会话并留在盘上，不清理。
    /// 跑完直接启动 app，就能看到会话列表从快照渲染出来的样子：
    ///     TEST_RUNNER_QRDROP_SEED_UI=1 xcodebuild test -only-testing:QrDropTests/CompletionProfileTests …
    @Test func seedSessionForManualUICheck() async throws {
        guard ProcessInfo.processInfo.environment["QRDROP_SEED_UI"] != nil else { return }
        try await ProgressDiskLock.withLock {
            let e2e = try Vectors.keyValues("e2e.txt")
            let T = Int(e2e["lt.T"]!)!, K = Int(e2e["lt.K"]!)!, m = Int(e2e["lt.m"]!)!
            let sid = UInt32(e2e["lt.sessionId"]!, radix: 16)!
            let src = TestEncoder.splitSourceBlocks(try Vectors.binary("stream.bin"), K: K, T: T)
            let composer = PeelingComposer(K: K)

            let engine = DecodeEngine()
            await engine.clearAll()
            var base: UInt32 = 0
            // 喂到大约六成，留一个进行中的会话
            while await (engine.sessionSnapshot(sid)?.stats.blocksUnique ?? 0) < K * 6 / 10 {
                let bytes = TestEncoder.encodeFrame(src: src, K: K, T: T, codec: .peeling,
                                                    compressed: false, sessionId: sid,
                                                    baseBlockId: base, m: m, composer: composer)
                await engine.processPayload(Data(bytes))
                base = base &+ UInt32(m)
            }
            await engine.saveAllProgress(force: true)
            let snap = try #require(await engine.sessionSnapshot(sid))
            TestReport.log("已造会话 \(SessionId.hex(sid))：编码块 \(snap.stats.blocksUnique)/\(snap.estimatedNeededBlocks)，源块 \(snap.solvedCount)/\(K)")
        }
    }

    private func profile(contentSize: Int, T: Int, m: Int) throws {
        var content = [UInt8](repeating: 0, count: contentSize)
        var s = Prng.mix32(UInt32(truncatingIfNeeded: contentSize))
        for i in 0..<contentSize { s = Prng.xorshift32(s); content[i] = UInt8(s & 0xFF) }
        // 随机内容不可压，allowCompress 关掉省时间
        let stream = try StreamCodec.buildStream(content: content, fileName: "profile.bin",
                                                 allowCompress: false).stream
        let K = (stream.count + T - 1) / T
        let sid: UInt32 = 0xC0FF_EE01
        let src = TestEncoder.splitSourceBlocks(stream, K: K, T: T)
        let composer = PeelingComposer(K: K)

        ProgressStore.remove(sessionId: sid)
        defer { ProgressStore.remove(sessionId: sid) }

        let session = ReceiveSession(sessionId: sid, K: K, T: T, codec: .peeling, compressed: false)
        let journal = try ProgressJournal(session: session)

        var base: UInt32 = 0
        var frameIndex = 0
        var ingestMs: [(frame: Int, solved: Int, ms: Double)] = []
        var journalTotalMs = 0.0
        var journalMaxMs = 0.0

        while !session.isComplete {
            let bytes = TestEncoder.encodeFrame(src: src, K: K, T: T, codec: .peeling, compressed: false,
                                                sessionId: sid, baseBlockId: base, m: m, composer: composer)
            let frame = try #require(FrameParser.parse(bytes))

            let t0 = CACurrentMediaTime()
            _ = session.ingest(frame)
            let ms = (CACurrentMediaTime() - t0) * 1000
            ingestMs.append((frameIndex, session.decoder.solvedCount, ms))

            let t1 = CACurrentMediaTime()
            try journal.append(session.decoder.takeJournal(), stats: session.stats)
            let jms = (CACurrentMediaTime() - t1) * 1000
            journalTotalMs += jms
            journalMaxMs = max(journalMaxMs, jms)

            base = base &+ UInt32(m)
            frameIndex += 1
        }

        // 收齐那一刻还会做的两件事
        let tMeta = CACurrentMediaTime()
        session.meta = nil
        session.tryExtractMeta()
        let metaMs = (CACurrentMediaTime() - tMeta) * 1000

        let tEnc = CACurrentMediaTime()
        let blob = ProgressStore.encode([session])
        let encodeMs = (CACurrentMediaTime() - tEnc) * 1000

        let tWrite = CACurrentMediaTime()
        try blob.write(to: ProgressStore.fileURL(for: sid), options: .atomic)
        let writeMs = (CACurrentMediaTime() - tWrite) * 1000

        journal.close()
        let logBytes = (try? Data(contentsOf: ProgressStore.logURL(for: sid)).count) ?? 0

        let top = ingestMs.sorted { $0.ms > $1.ms }.prefix(8)
        let totalIngest = ingestMs.reduce(0) { $0 + $1.ms }

        TestReport.log("=== 收齐时刻剖析 K=\(K) T=\(T) m=\(m) 共 \(frameIndex) 帧 ===")
        TestReport.log(String(format: "ingest 合计 %.0f ms，最慢 8 帧：", totalIngest))
        for e in top {
            TestReport.log(String(format: "  第 %d 帧（解出 %d/%d）：%.1f ms", e.frame, e.solved, K, e.ms))
        }
        TestReport.log(String(format: "日志追加 合计 %.0f ms，单次最慢 %.1f ms，日志 %d 字节",
                              journalTotalMs, journalMaxMs, logBytes))
        TestReport.log(String(format: "tryExtractMeta %.1f ms", metaMs))
        TestReport.log(String(format: "压实 encode %.0f ms + 写盘 %.0f ms，共 %d 字节",
                              encodeMs, writeMs, blob.count))
    }
}
