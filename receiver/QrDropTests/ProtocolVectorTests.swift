//
//  ProtocolVectorTests.swift
//  QrDropTests
//
//  逐条比对 protocol/vectors/ 下的跨语言测试向量，外加端到端解码、
//  丢帧模拟与 .vdpg 持久化往返。
//
//  向量文件的来源优先级：
//  1. 环境变量 VD_VECTORS_DIR，便于临时指向别处；
//  2. 测试 bundle 里的 vectors/ —— 即 QrDropTests/vectors，由同步组自动纳入资源；
//  3. 仅 macOS：#filePath 回溯到仓库根的 protocol/vectors。
//
//  为什么不直接用 #filePath 读 protocol/vectors：本仓库位于 ~/Documents 下，
//  模拟器进程读取该路径会触发 TCC 授权，headless 的 xcodebuild 无处弹窗，
//  open() 会一直阻塞（实测卡死 10 分钟以上）。因此把向量随测试 bundle 打包，
//  QrDropTests 的 "Verify Protocol Vectors" 构建阶段负责校验两份副本一致，
//  不一致直接报构建错误。更新向量后执行：
//      cp protocol/vectors/* receiver/QrDropTests/vectors/
//

import Testing
import Foundation
@testable import QrDrop

// MARK: - 向量文件定位与解析

/// 仅用于定位测试 bundle
final class VectorBundleAnchor {}

/// 把实测 ε 等关键数字写到宿主机 /private/tmp，便于抓取（Xcode 控制台同时可见）
enum TestReport {
    static let path = "/private/tmp/visiondrop-tests.log"

    static func log(_ line: String) {
        print(line)
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

enum Vectors {

    /// 记录候选路径，定位失败时给出可读的诊断信息
    static private(set) var searched: [String] = []

    static let directory: URL = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VD_VECTORS_DIR"] {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        let anchor = Bundle(for: VectorBundleAnchor.self)
        // 同步组把 vectors/ 里的文件当资源加入，可能保留子目录也可能平铺到 bundle 根
        for base in [anchor.resourceURL, anchor.bundleURL].compactMap({ $0 }) {
            candidates.append(base.appendingPathComponent("vectors", isDirectory: true))
            candidates.append(base)
        }
        #if os(macOS)
        // 仅 macOS 直接读仓库源码目录；模拟器读宿主机 ~/Documents 会被 TCC 阻塞
        candidates.append(repoDirectory)
        #endif

        for url in candidates {
            searched.append(url.path)
            if fm.fileExists(atPath: url.appendingPathComponent("prng.txt").path) { return url }
        }
        return candidates.first ?? repoDirectory
    }()

    /// 从测试文件路径向上回溯到仓库根，再进 protocol/vectors
    static var repoDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // QrDropTests
            .deletingLastPathComponent()      // receiver
            .deletingLastPathComponent()      // 仓库根
            .appendingPathComponent("protocol/vectors", isDirectory: true)
    }

    static func lines(_ name: String) throws -> [[String]] {
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n").compactMap { raw -> [String]? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            return line.split(separator: " ").map(String.init)
        }
    }

    static func binary(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: directory.appendingPathComponent(name)))
    }

    /// e2e.txt 是 <键> <值> 形式
    static func keyValues(_ name: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for parts in try lines(name) where parts.count >= 2 {
            out[parts[0]] = parts[1]
        }
        return out
    }

    static func hexToBytes(_ hex: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            out.append(UInt8(hex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        return out
    }

    static func bytesToHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 测试侧的编码器（接收端不发送，这里只为构造端到端用例）

enum TestEncoder {

    static func splitSourceBlocks(_ stream: [UInt8], K: Int, T: Int) -> [[UInt8]] {
        var padded = stream
        if padded.count < K * T {
            padded.append(contentsOf: [UInt8](repeating: 0, count: K * T - padded.count))
        }
        return (0..<K).map { Array(padded[($0 * T)..<(($0 + 1) * T)]) }
    }

    static func xorBlocks(_ src: [[UInt8]], _ idxs: [Int], _ T: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: T)
        for i in idxs { ByteOps.xorInPlace(&out, src[i]) }
        return out
    }

    static func encodeFrame(src: [[UInt8]], K: Int, T: Int, codec: Codec, compressed: Bool,
                            sessionId: UInt32, baseBlockId: UInt32, m: Int,
                            composer: BlockComposer) -> [UInt8] {
        var body = [UInt8]()
        body.reserveCapacity(m * T)
        for i in 0..<m {
            let bid = baseBlockId &+ UInt32(truncatingIfNeeded: i)
            body.append(contentsOf: xorBlocks(src, composer.neighborsOf(bid), T))
        }
        var head = [UInt8]()
        head.append(FrameParser.magic)
        head.append((FrameParser.protocolVersion << 4) | ((compressed ? 1 : 0) << 3) | (codec.rawValue << 2))
        ByteOps.appendUInt32(&head, sessionId)
        ByteOps.appendUInt24(&head, UInt32(K))
        ByteOps.appendUInt16(&head, UInt16(T))
        head.append(UInt8(m))
        ByteOps.appendUInt32(&head, baseBlockId)
        ByteOps.appendUInt32(&head, ByteOps.crc32(body))
        return head + body
    }

    static func composer(for codec: Codec, K: Int) -> BlockComposer {
        codec == .linearSolve ? LinearSolveComposer(K: K) : PeelingComposer(K: K)
    }
}

// MARK: - 1. PRNG

struct PrngVectorTests {

    @Test func vectorsAreReachable() {
        let ok = FileManager.default.fileExists(atPath: Vectors.directory.appendingPathComponent("prng.txt").path)
        #expect(ok, "未找到向量目录。已尝试：\(Vectors.searched.joined(separator: " | "))")
    }

    @Test func mix32AndXorshift32MatchVectors() throws {
        let rows = try Vectors.lines("prng.txt")
        #expect(rows.count >= 40)
        for row in rows {
            let input = UInt32(row[1], radix: 16)!
            let expected = UInt32(row[2], radix: 16)!
            let actual = row[0] == "mix32" ? Prng.mix32(input) : Prng.xorshift32(input)
            #expect(actual == expected, "\(row[0])(\(row[1])) 期望 \(row[2]) 实得 \(String(format: "%08x", actual))")
        }
    }
}

// MARK: - 2. Robust Soliton 量化 CDF

struct RobustSolitonVectorTests {

    @Test func quantizedCdfMatchesVectors() throws {
        let rows = try Vectors.lines("rs_cdf.txt")
        var cache: [Int: RobustSoliton] = [:]
        for row in rows {
            let K = Int(row[0])!
            let d = Int(row[1])!
            let expected = UInt64(row[2])!
            let soliton = cache[K] ?? {
                let s = RobustSoliton(K: K)
                cache[K] = s
                return s
            }()
            #expect(soliton.cdf[d] == expected, "K=\(K) d=\(d) 期望 \(expected) 实得 \(soliton.cdf[d])")
        }
    }
}

// MARK: - 3. LT 邻居集合

struct LtNeighborVectorTests {

    @Test func neighborsMatchVectors() throws {
        let rows = try Vectors.lines("lt_neighbors.txt")
        var cache: [Int: PeelingComposer] = [:]
        for row in rows {
            let K = Int(row[0])!
            let blockId = UInt32(row[1])!
            let degree = Int(row[2])!
            let expected = row[3].split(separator: ",").map { Int($0)! }
            let composer = cache[K] ?? {
                let c = PeelingComposer(K: K)
                cache[K] = c
                return c
            }()
            let actual = composer.neighborsOf(blockId)
            #expect(actual.count == degree, "K=\(K) blockId=\(blockId) 度数不符")
            #expect(actual == expected, "K=\(K) blockId=\(blockId) 邻居集合不符")
        }
    }
}

// MARK: - 4. RLNC 系数向量

struct RlncCoeffVectorTests {

    @Test func coefficientsMatchVectors() throws {
        let rows = try Vectors.lines("rlnc_coeff.txt")
        for row in rows {
            let K = Int(row[0])!
            let blockId = UInt32(row[1])!
            let expected = Vectors.hexToBytes(row[2])
            let actual = LinearSolveComposer(K: K).coefficients(blockId).littleEndianBytes
            #expect(actual == expected,
                    "K=\(K) blockId=\(blockId) 期望 \(row[2]) 实得 \(Vectors.bytesToHex(actual))")
        }
    }
}

// MARK: - 5. raw deflate

struct DeflateVectorTests {

    @Test func inflateMatchesPlainVector() throws {
        let plain = try Vectors.binary("deflate_plain.bin")
        let packed = try Vectors.binary("deflate_packed.bin")
        let restored = try StreamCodec.inflateRaw(packed)
        #expect(restored == plain, "inflate(packed) 必须逐字节等于 plain")
    }

    @Test func deflateInflateRoundTrip() throws {
        let plain = try Vectors.binary("deflate_plain.bin")
        let packed = try StreamCodec.deflateRaw(plain)
        #expect(packed.count < plain.count)
        #expect(try StreamCodec.inflateRaw(packed) == plain)
    }

    @Test func buildStreamRoundTrip() throws {
        let content = try Vectors.binary("fixture.bin")
        let built = try StreamCodec.buildStream(content: content, fileName: "fixture.bin", allowCompress: true)
        let parsed = try StreamCodec.parseStream(built.stream)
        #expect(parsed.content == content)
        #expect(parsed.meta.fileName == "fixture.bin")
        #expect(parsed.meta.compressed == built.compressed)
        #expect(parsed.meta.sha256 == StreamCodec.sha256(content))
    }

    @Test func parseStreamMatchesVectorStream() throws {
        let stream = try Vectors.binary("stream.bin")
        let e2e = try Vectors.keyValues("e2e.txt")
        let parsed = try StreamCodec.parseStream(stream)
        #expect(parsed.meta.fileName == e2e["fileName"])
        #expect(parsed.meta.compressed == false)
        #expect(parsed.content.count == Int(e2e["contentLen"]!))
        #expect(Vectors.bytesToHex(parsed.meta.sha256) == e2e["contentSha256"])
        #expect(Vectors.bytesToHex(StreamCodec.sha256(parsed.content)) == e2e["contentSha256"])
    }
}

// MARK: - 6. 帧解析 + sessionId

struct FrameVectorTests {

    private func check(codecName: String, codec: Codec) throws {
        let e2e = try Vectors.keyValues("e2e.txt")
        let expectedT = Int(e2e["\(codecName).T"]!)!
        let expectedK = Int(e2e["\(codecName).K"]!)!
        let expectedM = Int(e2e["\(codecName).m"]!)!
        let expectedSid = UInt32(e2e["\(codecName).sessionId"]!, radix: 16)!

        let stream = try Vectors.binary("stream.bin")
        let src = TestEncoder.splitSourceBlocks(stream, K: expectedK, T: expectedT)
        let composer = TestEncoder.composer(for: codec, K: expectedK)

        // sessionId 的确定性推导必须与向量一致
        let contentSha = Vectors.hexToBytes(e2e["contentSha256"]!)
        #expect(SessionId.derive(contentSha256: contentSha, T: expectedT, K: expectedK, codec: codec) == expectedSid)

        let rows = try Vectors.lines("frames_\(codecName).txt")
        #expect(rows.count >= 6)
        let decoder: BlockDecoder = codec == .linearSolve
            ? LinearSolveDecoder(K: expectedK, T: expectedT)
            : PeelingDecoder(K: expectedK, T: expectedT)

        for row in rows {
            let base = UInt32(row[0])!
            let bytes = Vectors.hexToBytes(row[1])

            // 本端编码器产出的整帧字节必须与向量逐字节一致
            let rebuilt = TestEncoder.encodeFrame(src: src, K: expectedK, T: expectedT, codec: codec,
                                                  compressed: false, sessionId: expectedSid,
                                                  baseBlockId: base, m: expectedM, composer: composer)
            #expect(rebuilt == bytes, "\(codecName) base=\(base) 整帧字节不一致")

            let frame = try #require(FrameParser.parse(bytes), "\(codecName) base=\(base) 帧解析失败")
            #expect(frame.sessionId == expectedSid)
            #expect(frame.K == expectedK)
            #expect(frame.T == expectedT)
            #expect(frame.m == expectedM)
            #expect(frame.codec == codec)
            #expect(frame.compressed == false)
            #expect(frame.baseBlockId == base)
            for i in 0..<frame.m {
                _ = decoder.add(blockId: frame.blockId(i), payload: frame.block(i))
            }
        }
        #expect(decoder.solvedCount > 0, "向量帧应当推进解码进度")
    }

    @Test func rlncFramesMatchVectors() throws { try check(codecName: "rlnc", codec: .linearSolve) }
    @Test func ltFramesMatchVectors() throws { try check(codecName: "lt", codec: .peeling) }

    @Test func corruptedFrameIsRejected() throws {
        let rows = try Vectors.lines("frames_rlnc.txt")
        var bytes = Vectors.hexToBytes(rows[0][1])
        #expect(FrameParser.parse(bytes) != nil)

        // CRC 覆盖偏移 20 之后，改一个体字节必须被拒
        bytes[25] ^= 0xFF
        #expect(FrameParser.parse(bytes) == nil, "帧体被篡改必须整帧丢弃")

        // magic / 版本 / 长度
        var wrongMagic = Vectors.hexToBytes(rows[0][1]); wrongMagic[0] = 0x57
        #expect(FrameParser.parse(wrongMagic) == nil)
        var wrongVersion = Vectors.hexToBytes(rows[0][1]); wrongVersion[1] = 0x20
        #expect(FrameParser.parse(wrongVersion) == nil)
        let truncated = Array(Vectors.hexToBytes(rows[0][1]).dropLast())
        #expect(FrameParser.parse(truncated) == nil)
    }
}

// MARK: - 7. 端到端 + 丢帧模拟

struct EndToEndTests {

    /// 返回 (收到的唯一块数, 帧数, 还原内容)
    private func run(codec: Codec, dropRate: Double, seed: UInt32) throws
        -> (blocks: Int, frames: Int, content: [UInt8], meta: StreamMeta, K: Int) {

        let e2e = try Vectors.keyValues("e2e.txt")
        let name = codec == .linearSolve ? "rlnc" : "lt"
        let T = Int(e2e["\(name).T"]!)!
        let K = Int(e2e["\(name).K"]!)!
        let m = Int(e2e["\(name).m"]!)!
        let sid = UInt32(e2e["\(name).sessionId"]!, radix: 16)!

        let stream = try Vectors.binary("stream.bin")
        let src = TestEncoder.splitSourceBlocks(stream, K: K, T: T)
        let composer = TestEncoder.composer(for: codec, K: K)

        let session = ReceiveSession(sessionId: sid, K: K, T: T, codec: codec, compressed: false)
        var state = Prng.mix32(seed ^ 0xABCD_1234)
        var base: UInt32 = 0
        var frames = 0

        while !session.isComplete {
            let bytes = TestEncoder.encodeFrame(src: src, K: K, T: T, codec: codec, compressed: false,
                                                sessionId: sid, baseBlockId: base, m: m, composer: composer)
            frames += 1
            state = Prng.xorshift32(state)
            let lost = (Double(state) / 4_294_967_296.0) < dropRate
            if !lost, let frame = FrameParser.parse(bytes) {
                _ = session.ingest(frame)
            }
            base = base &+ UInt32(m)
            if frames > K * 20 { break }
        }
        #expect(session.isComplete, "\(name) drop=\(dropRate) 未能解出全部源块")
        let result = try session.finalizeContent()
        return (session.stats.blocksUnique, frames, result.content, result.meta, K)
    }

    @Test(arguments: [0.0, 0.1, 0.3, 0.5])
    func linearSolveEndToEnd(dropRate: Double) throws {
        let e2e = try Vectors.keyValues("e2e.txt")
        let fixture = try Vectors.binary("fixture.bin")
        let r = try run(codec: .linearSolve, dropRate: dropRate, seed: UInt32(dropRate * 100) + 1)
        #expect(r.content == fixture)
        #expect(Vectors.bytesToHex(StreamCodec.sha256(r.content)) == e2e["contentSha256"])
        #expect(r.meta.fileName == "fixture.bin")
        let eps = Double(r.blocks) / Double(r.K) - 1
        TestReport.log(String(format: "解方程 丢帧 %.0f%% | %d 帧 | 收 %d 块 | K=%d | 实测 ε=%.2f%%",
                     dropRate * 100, r.frames, r.blocks, r.K, eps * 100))
    }

    @Test(arguments: [0.0, 0.1, 0.3, 0.5])
    func peelingEndToEnd(dropRate: Double) throws {
        let e2e = try Vectors.keyValues("e2e.txt")
        let fixture = try Vectors.binary("fixture.bin")
        let r = try run(codec: .peeling, dropRate: dropRate, seed: UInt32(dropRate * 100) + 7)
        #expect(r.content == fixture)
        #expect(Vectors.bytesToHex(StreamCodec.sha256(r.content)) == e2e["contentSha256"])
        #expect(r.meta.fileName == "fixture.bin")
        let eps = Double(r.blocks) / Double(r.K) - 1
        TestReport.log(String(format: "剥洋葱 丢帧 %.0f%% | %d 帧 | 收 %d 块 | K=%d | 实测 ε=%.2f%%",
                     dropRate * 100, r.frames, r.blocks, r.K, eps * 100))
    }
}

// MARK: - 8. .vdpg 持久化往返

struct ProgressStoreTests {

    /// 喂一半的帧 -> 存盘 -> 读回 -> 继续喂到完成，校验哈希
    private func roundTrip(codec: Codec) throws {
        let e2e = try Vectors.keyValues("e2e.txt")
        let name = codec == .linearSolve ? "rlnc" : "lt"
        let T = Int(e2e["\(name).T"]!)!
        let K = Int(e2e["\(name).K"]!)!
        let m = Int(e2e["\(name).m"]!)!
        let sid = UInt32(e2e["\(name).sessionId"]!, radix: 16)!

        let stream = try Vectors.binary("stream.bin")
        let fixture = try Vectors.binary("fixture.bin")
        let src = TestEncoder.splitSourceBlocks(stream, K: K, T: T)
        let composer = TestEncoder.composer(for: codec, K: K)

        let session = ReceiveSession(sessionId: sid, K: K, T: T, codec: codec, compressed: false)
        var base: UInt32 = 0
        // 先喂进大约一半的编码块
        while session.stats.blocksUnique < K / 2 {
            let bytes = TestEncoder.encodeFrame(src: src, K: K, T: T, codec: codec, compressed: false,
                                                sessionId: sid, baseBlockId: base, m: m, composer: composer)
            _ = session.ingest(try #require(FrameParser.parse(bytes)))
            base = base &+ UInt32(m)
        }
        let solvedBefore = session.decoder.solvedCount
        let uniqueBefore = session.stats.blocksUnique

        let data = ProgressStore.encode([session])
        let restored = try #require(try ProgressStore.decode(data).first)

        #expect(restored.sessionId == sid)
        #expect(restored.K == K)
        #expect(restored.T == T)
        #expect(restored.codec == codec)
        #expect(restored.decoder.solvedCount == solvedBefore, "恢复后解码状态必须一致")
        #expect(restored.stats.blocksUnique == uniqueBefore)

        // 继续喂到完成
        while !restored.isComplete {
            let bytes = TestEncoder.encodeFrame(src: src, K: K, T: T, codec: codec, compressed: false,
                                                sessionId: sid, baseBlockId: base, m: m, composer: composer)
            _ = restored.ingest(try #require(FrameParser.parse(bytes)))
            base = base &+ UInt32(m)
        }
        let result = try restored.finalizeContent()
        #expect(result.content == fixture)
        TestReport.log("\(codec.displayName) .vdpg 往返：\(data.count) 字节，恢复后源块 \(solvedBefore)/\(K)，续解完成")
    }

    @Test func linearSolveProgressRoundTrip() throws { try roundTrip(codec: .linearSolve) }
    @Test func peelingProgressRoundTrip() throws { try roundTrip(codec: .peeling) }

    @Test func diskRoundTripAndCleanup() throws {
        let e2e = try Vectors.keyValues("e2e.txt")
        let T = Int(e2e["lt.T"]!)!
        let K = Int(e2e["lt.K"]!)!
        let m = Int(e2e["lt.m"]!)!
        let sid = UInt32(e2e["lt.sessionId"]!, radix: 16)!
        let stream = try Vectors.binary("stream.bin")
        let src = TestEncoder.splitSourceBlocks(stream, K: K, T: T)
        let composer = PeelingComposer(K: K)

        let session = ReceiveSession(sessionId: sid, K: K, T: T, codec: .peeling, compressed: false)
        let bytes = TestEncoder.encodeFrame(src: src, K: K, T: T, codec: .peeling, compressed: false,
                                            sessionId: sid, baseBlockId: 0, m: m, composer: composer)
        _ = session.ingest(try #require(FrameParser.parse(bytes)))

        try ProgressStore.save(session)
        let url = ProgressStore.fileURL(for: sid)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reloaded = try #require(try ProgressStore.decode(try Data(contentsOf: url)).first)
        #expect(reloaded.decoder.solvedCount == session.decoder.solvedCount)

        ProgressStore.remove(sessionId: sid)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rejectsBadMagic() {
        let bogus = Data([0x00, 0x01, 0x02, 0x03, 0x00, 0x01, 0x00, 0x00])
        #expect(throws: ProgressStoreError.self) { try ProgressStore.decode(bogus) }
    }
}
