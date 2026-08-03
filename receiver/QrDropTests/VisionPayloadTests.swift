//
//  VisionPayloadTests.swift
//  QrDropTests
//
//  Vision 载荷取字节路径的回归测试。
//
//  这条路径此前没有测试覆盖：所有端到端测试都是把帧字节直接喂给 FrameParser，
//  从未经过 Vision。结果是「payloadData 返回的是 QR 原始数据码字而非写进去的字节」
//  这件事一路漏到现场，表现为每一帧的 magic 校验都失败，即「完全识别不了」。
//
//  注意：**iOS 模拟器跑不了 Vision 的条码检测**，会抛
//  `com.apple.Vision Code=9 "Could not create inference context"`。
//  所以主回归测试是向量驱动的（qr_codewords.txt 里存的是真实 Vision 读出的码字），
//  活体 Vision 往返测试只在能跑的环境（真机 / macOS）执行，其余环境跳过。
//

import Testing
import Foundation
import CoreImage
import Vision
@testable import QrDrop

// MARK: - 向量驱动（所有环境都跑）

struct QRByteSegmentVectorTests {

    /// 从真实 QR 码字流中取出字节模式段，必须逐字节还原出原帧
    @Test func extractsFrameFromRealCodewords() throws {
        let rows = try Vectors.lines("qr_codewords.txt")
        #expect(rows.count >= 4, "码字向量过少")
        for parts in rows {
            let version = Int(parts[0])!
            let expected = Vectors.hexToBytes(parts[1])
            let codewords = Vectors.hexToBytes(parts[2])

            let got = QRByteSegment.extract(codewords: codewords, symbolVersion: version)
            #expect(got != nil, "V\(version) 取字节失败")
            #expect(got == expected, "V\(version) 取出的字节与原帧不一致")

            // 取出后必须能通过 FrameParser 的全部校验（含 CRC32）
            let parsed = FrameParser.parse(got ?? [])
            #expect(parsed != nil, "V\(version) 取字节后帧解析失败")
        }
    }

    /// 直接把原始码字当帧字节用必然失败——记录这个坑，防止有人「简化」掉 QRByteSegment
    @Test func rawCodewordsAreNotFrameBytes() throws {
        for parts in try Vectors.lines("qr_codewords.txt") {
            let expected = Vectors.hexToBytes(parts[1])
            let codewords = Vectors.hexToBytes(parts[2])
            #expect(codewords.first != expected.first,
                    "码字首字节竟与帧首字节相同，Vision 行为可能已变，请复核 QRByteSegment")
            #expect(codewords.count > expected.count, "码字流应比帧长（含计数字段与填充）")
            #expect(FrameParser.parse(codewords) == nil, "原始码字不该能通过帧校验")
        }
    }

    /// 8 bit 与 16 bit 两种字符计数分支都要覆盖
    @Test func coversBothCountFieldWidths() throws {
        let versions = try Vectors.lines("qr_codewords.txt").map { Int($0[0])! }
        #expect(versions.contains { $0 <= 9 }, "缺少 8bit 计数（V1-V9）的样本")
        #expect(versions.contains { $0 >= 10 }, "缺少 16bit 计数（V10-V40）的样本")
    }

    /// 截断的码字流不得让解析器越界
    @Test func truncatedCodewordsAreRejected() throws {
        let parts = try Vectors.lines("qr_codewords.txt")[0]
        let codewords = Vectors.hexToBytes(parts[2])
        for keep in [0, 1, 2, 3, codewords.count / 2] {
            let got = QRByteSegment.extract(codewords: Array(codewords.prefix(keep)),
                                            symbolVersion: Int(parts[0])!)
            #expect(got == nil, "截断到 \(keep) 字节仍返回了内容")
        }
    }
}

// MARK: - CIDetector 取二进制

/// 设计文档 1.2 把「AVFoundation / CIDetector 拿不到二进制载荷」列为硬约束。
/// 实测不成立：`messageString` 确实为 nil，但 `CIQRCodeFeature.symbolDescriptor`
/// 给出的 `CIQRCodeDescriptor.errorCorrectedPayload` 就是原始数据码字。
/// `AVMetadataMachineReadableCodeObject.descriptor` 是同一类型，同理可用。
///
/// CIDetector 不走 Vision 的 ML 推理，模拟器上可以跑，因此这里能做真正的往返测试。
struct CIDetectorBinaryTests {

    private func renderQR(_ payload: [UInt8]) -> CGImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        // 黑模块 + 透明底必须先合成到白底，否则检测不出
        let composited = scaled.composited(over: CIImage(color: .white).cropped(to: scaled.extent))
        return CIContext(options: nil).createCGImage(composited, from: composited.extent)
    }

    @Test(arguments: [64, 300, 1200])
    func ciDetectorRecoversBinaryPayload(length: Int) throws {
        var payload = [UInt8](repeating: 0, count: length)
        var s = Prng.mix32(UInt32(length) &+ 7)
        for i in 0..<length {
            s = Prng.xorshift32(s)
            payload[i] = UInt8(s & 0xFF)
        }
        payload[0] = 0x56
        payload[1] = 0x00
        payload[length - 1] = 0xFF

        let cg = try #require(renderQR(payload), "二维码渲染失败")
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: cg)) as? [CIQRCodeFeature] ?? []
        let feature = try #require(features.first, "CIDetector 未检出二维码")

        // 二进制载荷下 messageString 为 nil —— 这正是设计文档误判的来源
        #expect(feature.messageString == nil, "二进制载荷不该有可解的字符串")

        let descriptor = try #require(feature.symbolDescriptor, "symbolDescriptor 为 nil")
        let got = FileReceiver.rawPayload(descriptor: descriptor, fallbackString: feature.messageString)
        #expect(got != nil, "取二进制失败")
        #expect(got.map { [UInt8]($0) } == payload, "取出的字节与写入的不一致")
    }

    /// 真实帧经 CIDetector 往返后必须仍能通过 FrameParser 的全部校验
    @Test func realFrameSurvivesCIDetectorRoundTrip() throws {
        let stream = try Vectors.binary("stream.bin")
        let e2e = try Vectors.keyValues("e2e.txt")
        let T = Int(e2e["rlnc.T"]!)!, K = Int(e2e["rlnc.K"]!)!
        let sid = UInt32(e2e["rlnc.sessionId"]!, radix: 16)!
        let m = 8
        let src = TestEncoder.splitSourceBlocks(stream, K: K, T: T)
        let frame = TestEncoder.encodeFrame(src: src, K: K, T: T, codec: .linearSolve,
                                            compressed: false, sessionId: sid,
                                            baseBlockId: 0, m: m,
                                            composer: LinearSolveComposer(K: K))
        let cg = try #require(renderQR(frame))
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: cg)) as? [CIQRCodeFeature] ?? []
        let feature = try #require(features.first)
        let got = try #require(FileReceiver.rawPayload(descriptor: feature.symbolDescriptor,
                                                       fallbackString: feature.messageString))
        #expect([UInt8](got) == frame)

        let parsed = try #require(FrameParser.parse([UInt8](got)), "往返后帧解析失败")
        #expect(parsed.sessionId == sid)
        #expect(parsed.K == K)
        #expect(parsed.T == T)
        #expect(parsed.m == m)
    }
}

// MARK: - 活体 Vision 往返（模拟器不支持，自动跳过）

struct VisionPayloadTests {

    /// 用 CoreImage 生成二维码，再用 Vision 读回来。
    /// Vision 不可用时返回 nil 由调用方跳过。
    private func roundTrip(_ payload: [UInt8]) -> [UInt8]?? {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return .some(nil) }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        // CIQRCodeGenerator 产出黑模块 + 透明底，必须先合成到白底，否则渲染成黑底黑码
        let composited = scaled.composited(over: CIImage(color: .white).cropped(to: scaled.extent))
        guard let cg = CIContext(options: nil).createCGImage(composited, from: composited.extent) else {
            return .some(nil)
        }
        let req = VNDetectBarcodesRequest()
        req.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        } catch {
            return nil          // Vision 不可用（模拟器），跳过
        }
        guard let obs = (req.results ?? []).first(where: { $0.symbology == .qr }) else {
            return .some(nil)
        }
        let descriptor = obs.barcodeDescriptor as? CIQRCodeDescriptor
        let codewords: [UInt8]? = descriptor.map { [UInt8]($0.errorCorrectedPayload) }
            ?? obs.payloadData.map { [UInt8]($0) }
        guard let codewords else { return .some(nil) }
        return .some(QRByteSegment.extract(codewords: codewords,
                                           symbolVersion: descriptor.map { Int($0.symbolVersion) } ?? 40))
    }

    /// 覆盖含 0x00 / 0xFF 的任意二进制，这是本协议的实际载荷形态
    @Test(arguments: [64, 300, 900, 1500])
    func binaryPayloadSurvivesVisionRoundTrip(length: Int) throws {
        var payload = [UInt8](repeating: 0, count: length)
        var s = Prng.mix32(UInt32(length))
        for i in 0..<length {
            s = Prng.xorshift32(s)
            payload[i] = UInt8(s & 0xFF)
        }
        payload[0] = 0x56
        payload[1] = 0x00
        payload[length - 1] = 0xFF

        guard let result = roundTrip(payload) else { return }   // Vision 不可用，跳过
        #expect(result != nil, "Vision 未检出二维码")
        #expect(result == payload, "取出的字节与写入的不一致")
    }
}
