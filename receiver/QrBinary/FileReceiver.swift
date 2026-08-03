//
//  FileReceiver.swift
//  QrBinary
//
//  Created by Victor on 2026/2/21.
//

import Foundation
import Combine
import SwiftUI
import CoreImage
import Vision
import UIKit

// MARK: - 识别引擎

enum QREngine: String, CaseIterable, Identifiable {
    case avFoundation = "AVFoundation"
    case vision = "Vision"

    var id: String { rawValue }

    /// 两种引擎都能取二进制：Vision 走 payloadData / barcodeDescriptor，
    /// AVFoundation 走 AVMetadataMachineReadableCodeObject.descriptor，
    /// 都是 CIQRCodeDescriptor 的原始数据码字（见 QRByteSegment）。
    /// 设计文档 1.2 把「AVFoundation 拿不到二进制」列为硬约束，实测不成立。
    var supportsBinaryPayload: Bool { true }
}

// MARK: - 扫描分辨率

enum ScanResolution: String, CaseIterable, Identifiable {
    case hd720p = "720p"
    case hd1080p = "1080p"

    var id: String { rawValue }
}

// MARK: - 旧 JSON 格式（兼容分支，只保留解析与重组）

struct QRChunk: Codable, Sendable {
    let fileId: String
    let fileName: String
    let totalChunks: Int
    let chunkIndex: Int
    let data: String  // base64
    let crc32: UInt32
}

/// 旧格式的单个文件状态，取代原先的 files / fileInfo 两个平行字典
final class LegacyFile: Identifiable {
    let fileId: String
    let fileName: String
    let totalChunks: Int
    var chunks: [Int: Data] = [:]

    var id: String { fileId }
    var isComplete: Bool { chunks.count == totalChunks }

    init(fileId: String, fileName: String, totalChunks: Int) {
        self.fileId = fileId
        self.fileName = fileName
        self.totalChunks = totalChunks
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let isError: Bool
}

// MARK: - FileReceiver

@MainActor
class FileReceiver: ObservableObject {

    /// 新二进制协议的会话，以 sessionId 为主键
    @Published var sessions: [UInt32: ReceiveSession] = [:]
    /// 旧 JSON 格式的文件
    @Published var legacyFiles: [String: LegacyFile] = [:]
    @Published var logs: [LogEntry] = []
    @Published var selectedEngine: QREngine = .vision
    /** 扫描最大帧率，5/10/15/20/25/30 六档，默认 20fps */
    @Published var maxScanFps: Int = 20
    /** 摄像头分辨率，默认 720p */
    @Published var scanResolution: ScanResolution = .hd720p
    /// 会话内部状态变化时递增，驱动 SwiftUI 刷新（ReceiveSession 是引用类型）
    @Published var revision: Int = 0

    /// 接收速率统计，按去重后的编码块字节数计
    let throughput = ThroughputMeter()

    /// 自动保存间隔，设计 9.3
    private let autoSaveInterval: TimeInterval = 5
    private var backgroundObserver: NSObjectProtocol?

    init() {
        restoreProgress()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let receiver = self else { return }
            Task { @MainActor in receiver.saveAllProgress(force: true) }
        }
    }

    deinit {
        if let observer = backgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var sortedSessions: [ReceiveSession] {
        sessions.values.sorted { $0.sessionId < $1.sessionId }
    }

    var sortedLegacyFiles: [LegacyFile] {
        legacyFiles.values.sorted { $0.fileId < $1.fileId }
    }

    // MARK: - 日志

    func addLog(_ message: String, isError: Bool = false) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: Date())
        let entry = LogEntry(timestamp: Date(), message: "[\(timeStr)] \(message)", isError: isError)
        logs.append(entry)
        if logs.count > 500 { logs.removeFirst(100) }
    }

    // MARK: - 载荷分流（设计 12.1）

    /// 按首字节分流：0x56 走新二进制协议，0x7B（'{'）走旧 JSON 分支
    @discardableResult
    func processPayload(_ payload: Data) -> Bool {
        guard let first = payload.first else { return false }
        switch first {
        case FrameParser.magic:
            return processBinaryFrame([UInt8](payload))
        case 0x7B:
            guard let text = String(data: payload, encoding: .utf8) else { return false }
            return processLegacyJSON(text)
        default:
            return false
        }
    }

    // MARK: - 新二进制协议

    private func processBinaryFrame(_ bytes: [UInt8]) -> Bool {
        guard let frame = FrameParser.parse(bytes) else {
            // 整帧丢弃：长度 / magic / 版本 / CRC 任一失败
            if bytes.count >= 6 {
                let sid = ByteOps.readUInt32(bytes, 2)
                sessions[sid]?.stats.framesRejected += 1
            }
            revision &+= 1
            return false
        }

        let session: ReceiveSession
        if let existing = sessions[frame.sessionId] {
            // 参数不一致说明 sessionId 撞车，丢弃该帧而不是污染已有会话
            guard existing.K == frame.K, existing.T == frame.T, existing.codec == frame.codec else {
                existing.stats.framesRejected += 1
                addLog("会话 \(SessionId.hex(frame.sessionId)) 参数不一致，整帧丢弃", isError: true)
                return false
            }
            session = existing
        } else {
            session = ReceiveSession(frame: frame)
            sessions[frame.sessionId] = session
            addLog("新会话 \(SessionId.hex(frame.sessionId))：K=\(frame.K) T=\(frame.T) \(frame.codec.displayName)")
        }

        // 已完成或正在后台还原的会话不再吃新块：既是白做功，也会与后台读取解码器状态打架
        guard !session.isComplete, !session.isFinalizing else {
            session.stats.framesAccepted += 1
            return false
        }

        // 只把去重后新增的块计入速率，重复帧不算（见 ThroughputMeter 的说明）
        let uniqueBefore = session.stats.blocksUnique
        let gained = session.ingest(frame)
        let newBlocks = session.stats.blocksUnique - uniqueBefore
        if newBlocks > 0 {
            throughput.record(bytes: newBlocks * session.T)
        }
        revision &+= 1

        if session.isComplete && !session.isFinished {
            // 收齐后不自动合并：合并是一次时长不可预测的 CPU 任务（解方程的回代是 O(K^2)），
            // 交给用户在主界面手动触发，避免它在传输刚结束时突然占住机器。
            // 但必须立刻落一次盘，否则退出后这些块就白收了。
            persist(session)
            addLog("已收齐 \(session.displayName)：\(session.K) 个源块，等待手动合并")
        } else if gained, Date().timeIntervalSince(session.lastSavedAt) > autoSaveInterval {
            persist(session)
        }
        return gained
    }

    /// 完成：拼接 -> parseStream -> 解压 -> 校验 SHA-256 -> 落盘 -> 删除进度文件
    ///
    /// 全程放后台。解方程方案的回代是 O(K^2) 次块异或，K=2503 时实测 Release 约 90 ms、
    /// Debug 达 6–8 秒；放主线程会在「传输刚完成」这一刻直接冻住界面。
    private func completeSession(_ session: ReceiveSession) {
        guard !session.isFinalizing else { return }
        session.isFinalizing = true
        revision &+= 1

        session.finalizeProgress = 0
        let cancelFlag = CancellationFlag()
        session.finalizeCancel = cancelFlag
        let startedAt = Date()
        let sessionId = session.sessionId
        let decoder = session.decoder
        addLog("开始还原 \(SessionId.hex(sessionId))：K=\(session.K) T=\(session.T) \(session.codec.displayName)")

        Task.detached(priority: .userInitiated) {
            var tAssemble = 0.0, tParse = 0.0, tHash = 0.0, tWrite = 0.0
            let outcome: Result<(StreamMeta, Int, URL), Error>
            do {
                var mark = Date()
                let assembled = decoder.assemble(
                    progress: { p in
                        Task { @MainActor in session.finalizeProgress = p }
                    },
                    isCancelled: { cancelFlag.isSet })
                tAssemble = Date().timeIntervalSince(mark)
                guard let assembled else { throw StreamError.cancelled }

                mark = Date()
                let parsed = try StreamCodec.parseStream(assembled)
                tParse = Date().timeIntervalSince(mark)

                mark = Date()
                let digestOK = StreamCodec.sha256(parsed.content) == parsed.meta.sha256
                tHash = Date().timeIntervalSince(mark)
                guard digestOK else { throw StreamError.digestMismatch }

                mark = Date()
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("received", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(FileReceiver.sanitize(parsed.meta.fileName))
                try Data(parsed.content).write(to: url, options: .atomic)
                tWrite = Date().timeIntervalSince(mark)
                outcome = .success((parsed.meta, parsed.content.count, url))
            } catch {
                outcome = .failure(error)
            }

            await MainActor.run { [weak self] in
                session.isFinalizing = false
                session.finalizeProgress = 0
                session.finalizeCancel = nil
                let total = Int(Date().timeIntervalSince(startedAt) * 1000)
                switch outcome {
                case .success(let (meta, size, url)):
                    session.meta = meta
                    session.savedFileURL = url
                    session.finalSize = size
                    // 中间态到此为止：编码块 / 源块 / 消元基全部释放，
                    // 大文件下这部分是文件本身的 1.3–1.5 倍，留着会一直压着内存
                    session.decoder.releaseStorage()
                    ProgressStore.remove(sessionId: sessionId)
                    self?.addLog("接收完成：\(meta.fileName)（\(size) 字节，SHA-256 通过）")
                    self?.addLog(String(format: "  耗时 合计%dms = 拼接%.0f + 解流%.0f + 校验%.0f + 写盘%.0f",
                                        total, tAssemble * 1000, tParse * 1000, tHash * 1000, tWrite * 1000))
                    self?.addLog("  已释放中间态，\(Diagnostics.memoryTag())")
                case .failure(let error):
                    if case StreamError.cancelled = error {
                        session.failureMessage = nil
                        self?.addLog("会话 \(SessionId.hex(sessionId)) 合并已中止", isError: true)
                    } else {
                        session.failureMessage = error.localizedDescription
                        self?.addLog("会话 \(SessionId.hex(sessionId)) 还原失败：\(error.localizedDescription)", isError: true)
                    }
                }
                self?.revision &+= 1
            }
        }
    }

    /// 用户中止合并
    func cancelFinalize(_ session: ReceiveSession) {
        guard session.isFinalizing else { return }
        session.finalizeCancel?.set()
        addLog("正在中止 \(SessionId.hex(session.sessionId)) 的合并…")
    }

    /// 用户手动触发合并（收齐之后、中止之后、失败之后都走这里）
    func startFinalize(_ session: ReceiveSession) {
        guard !session.isFinished, !session.isFinalizing, session.isComplete else { return }
        session.failureMessage = nil
        completeSession(session)
    }

    /// 去掉路径分隔符，避免恶意文件名写到目录外
    nonisolated static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return cleaned.isEmpty ? "received.bin" : cleaned
    }

    // MARK: - 旧 JSON 分支

    private func processLegacyJSON(_ text: String) -> Bool {
        guard let jsonData = text.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(QRChunk.self, from: jsonData) else {
            return false
        }
        let file = legacyFiles[chunk.fileId] ?? {
            let f = LegacyFile(fileId: chunk.fileId, fileName: chunk.fileName, totalChunks: chunk.totalChunks)
            legacyFiles[chunk.fileId] = f
            return f
        }()
        if file.chunks[chunk.chunkIndex] != nil { return false }

        guard let dataBytes = Data(base64Encoded: chunk.data) else {
            addLog("旧格式片段 \(chunk.chunkIndex) base64 解码失败", isError: true)
            return false
        }
        guard ByteOps.crc32([UInt8](dataBytes)) == chunk.crc32 else {
            addLog("旧格式片段 \(chunk.chunkIndex) CRC32 校验失败", isError: true)
            return false
        }
        file.chunks[chunk.chunkIndex] = dataBytes
        throughput.record(bytes: dataBytes.count)
        revision &+= 1
        addLog("旧格式片段 \(chunk.chunkIndex + 1)/\(chunk.totalChunks) - \(chunk.fileName)")
        if file.isComplete { addLog("旧格式文件 \(chunk.fileName) 接收完成") }
        return true
    }

    // MARK: - 从图片识别（照片导入）

    func processImage(_ cgImage: CGImage) -> Bool {
        switch selectedEngine {
        case .avFoundation:
            return processImageWithCIDetector(cgImage)
        case .vision:
            return processImageWithVision(cgImage)
        }
    }

    private func processImageWithCIDetector(_ cgImage: CGImage) -> Bool {
        let ciImage = CIImage(cgImage: cgImage)
        let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                  context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        guard let features = detector?.features(in: ciImage) as? [CIQRCodeFeature] else { return false }

        var processed = false
        for feature in features {
            // CIQRCodeFeature.symbolDescriptor（iOS 11 起）同样给出原始数据码字，
            // messageString 在二进制载荷下为 nil 并不代表取不到字节
            if let data = FileReceiver.rawPayload(descriptor: feature.symbolDescriptor,
                                                  fallbackString: feature.messageString),
               processPayload(data) {
                processed = true
            }
        }
        return processed
    }

    private func processImageWithVision(_ cgImage: CGImage) -> Bool {
        var processed = false
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            for result in request.results ?? [] where result.symbology == .qr {
                if let data = FileReceiver.rawPayload(of: result), processPayload(data) {
                    processed = true
                }
            }
        } catch {
            addLog("Vision 识别失败: \(error.localizedDescription)", isError: true)
        }
        return processed
    }

    /// 取原始二进制载荷。
    ///
    /// 注意 payloadData 给的是 QR 的原始数据码字（4bit 模式 + 8/16bit 长度 + 数据 + 填充），
    /// 不是写进二维码的那串字节，必须按位取出字节模式段，详见 QRByteSegment。
    /// 优先用 CIQRCodeDescriptor 拿到确切的符号版本；拿不到时按 V10+ 的 16 bit 计数假定，
    /// 本协议最低档为 V15，该假定成立。
    nonisolated static func rawPayload(of observation: VNBarcodeObservation) -> Data? {
        var codewords: [UInt8]?
        let descriptor = observation.barcodeDescriptor as? CIQRCodeDescriptor
        if let descriptor {
            codewords = [UInt8](descriptor.errorCorrectedPayload)
        } else if #available(iOS 17.0, *), let data = observation.payloadData {
            codewords = [UInt8](data)
        }
        return rawPayload(codewords: codewords,
                          symbolVersion: descriptor.map { Int($0.symbolVersion) },
                          fallbackString: observation.payloadStringValue)
    }

    /// AVFoundation 元数据输出与 CIDetector 共用：两者都能给出 CIQRCodeDescriptor
    nonisolated static func rawPayload(descriptor: CIQRCodeDescriptor?,
                                       fallbackString: String?) -> Data? {
        rawPayload(codewords: descriptor.map { [UInt8]($0.errorCorrectedPayload) },
                   symbolVersion: descriptor.map { Int($0.symbolVersion) },
                   fallbackString: fallbackString)
    }

    /// 三条识别路径的共同出口：原始码字 -> 字节模式段；取不到时退回字符串载荷
    private nonisolated static func rawPayload(codewords: [UInt8]?,
                                               symbolVersion: Int?,
                                               fallbackString: String?) -> Data? {
        if let codewords,
           let bytes = QRByteSegment.extract(codewords: codewords,
                                             symbolVersion: symbolVersion ?? 40) {
            return Data(bytes)
        }
        // 旧 JSON 格式带 ECI 段（模式 0111），取字节模式段会失败，走字符串载荷
        return fallbackString?.data(using: .utf8)
    }

    // MARK: - 进度持久化

    private func persist(_ session: ReceiveSession) {
        let started = Date()
        do {
            try ProgressStore.save(session)
            let ms = Diagnostics.elapsedMs(since: started)
            if ms > 200 {
                addLog("进度写盘偏慢：\(SessionId.hex(session.sessionId)) 耗时 \(ms) ms")
            }
        } catch {
            addLog("进度保存失败：\(error.localizedDescription)", isError: true)
        }
    }

    /// App 进入后台时全量保存
    func saveAllProgress(force: Bool) {
        let started = Date()
        var saved = 0
        // 已合并落盘的会话没有中间态可存，其进度文件在落盘时已删除；
        // 收齐但尚未合并的仍必须保存，否则退出即丢
        for session in sessions.values where !session.isFinished && !session.decoder.isReleased {
            if force || Date().timeIntervalSince(session.lastSavedAt) > autoSaveInterval {
                persist(session)
                saved += 1
            }
        }
        let ms = Diagnostics.elapsedMs(since: started)
        if force && (saved > 0 || ms > 50) {
            addLog("保存进度：\(saved) 个会话，耗时 \(ms) ms，\(Diagnostics.memoryTag())")
        }
    }

    /// App 启动时扫描目录恢复
    func restoreProgress() {
        let loaded = ProgressStore.loadAll()
        for session in loaded.sessions where sessions[session.sessionId] == nil {
            sessions[session.sessionId] = session
        }
        if !loaded.sessions.isEmpty {
            addLog("已恢复 \(loaded.sessions.count) 个会话进度")
        }
        for msg in loaded.failures {
            addLog("进度文件读取失败 \(msg)", isError: true)
        }
    }

    // MARK: - 导出/导入（跨设备迁移，与磁盘格式相同，sessionCount 可 > 1）

    func encodeProgress() throws -> Data {
        ProgressStore.encode(sortedSessions.filter { !$0.isComplete })
    }

    func loadProgress(from data: Data) throws {
        let restored = try ProgressStore.decode(data)
        for session in restored {
            sessions[session.sessionId] = session
            try? ProgressStore.save(session)
        }
        revision &+= 1
        addLog("进度已导入，包含 \(restored.count) 个会话")
    }

    // MARK: - 清理

    /// 清空全部接收数据：会话列表、旧格式文件、进度文件、已落盘的最终文件。
    ///
    /// 三处必须一起清。只删进度文件而留下内存里的 sessions，5 秒后的自动保存会把
    /// 它们原样写回，等于没清；只清 sessions 而留下 received/ 下的最终文件，
    /// 那些文件在 app 内再也没有入口可以访问到，只能占着空间。
    func clearAll() {
        sessions.removeAll()
        legacyFiles.removeAll()
        throughput.reset()
        let progressCount = ProgressStore.clearAll()
        let fileCount = FileReceiver.clearReceivedFiles()
        revision &+= 1
        addLog("数据已清空：\(progressCount) 个进度文件，\(fileCount) 个已接收文件")
    }

    /// 删除 received/ 目录下已落盘的最终文件，返回删除个数
    private static func clearReceivedFiles() -> Int {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("received", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                     includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }
}
