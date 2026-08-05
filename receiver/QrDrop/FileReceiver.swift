//
//  FileReceiver.swift
//  QrDrop
//
//  Created by Victor on 2026/2/21.
//
//  界面门面。解码、持久化、合并全部归 DecodeEngine（actor）所有，本类不持有任何
//  会话对象，只按固定节拍取一份不可变快照供 SwiftUI 渲染，并把用户操作转发进去。
//  这样取景与界面不会被喷泉码的雪崩剥离堵住——那一步在 5 MB 文件上是几百毫秒级的。
//

import Foundation
import Combine
import SwiftUI
import CoreImage
import Vision
import UIKit

// MARK: - 识别引擎

enum QREngine: String, CaseIterable, Identifiable, Sendable {
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

enum ScanResolution: String, CaseIterable, Identifiable, Sendable {
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
final class FileReceiver: ObservableObject {

    /// 会话快照，由 refreshLoop 按节拍从 engine 拉取
    @Published private(set) var sessions: [SessionSnapshot] = []
    /// 旧 JSON 格式文件的快照
    @Published private(set) var legacyFiles: [LegacyFileSnapshot] = []
    @Published var logs: [LogEntry] = []
    @Published var selectedEngine: QREngine = .vision
    /** 扫描最大帧率，5/10/15/20/25/30 六档，默认 30fps */
    @Published var maxScanFps: Int = 30
    /** 摄像头分辨率，默认 1080p */
    @Published var scanResolution: ScanResolution = .hd1080p

    /// 解码与持久化的唯一所有者
    let engine = DecodeEngine()

    /// 接收速率统计，按去重后的编码块字节数计。自带锁，可直接读
    nonisolated var throughput: ThroughputMeter { engine.throughput }

    /// 快照拉取节拍。雪崩那一刻会一次产生上万次状态变化，
    /// 逐次推送等于把卡顿换成刷新风暴，因此定频拉取而非变更即推
    private let refreshInterval: Duration = .milliseconds(100)

    init() {
        Task { [engine] in
            await engine.restoreProgress()
            await self.refresh()
        }
    }

    // MARK: - 快照拉取

    /// 由 ContentView 的 .task 驱动，视图消失时自动取消
    func runRefreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: refreshInterval)
        }
    }

    /// 取一份快照。仅在内容真的变了时才写 @Published，避免空转触发 SwiftUI 重绘
    func refresh() async {
        let snap = await engine.snapshot()
        if sessions != snap.sessions { sessions = snap.sessions }
        if legacyFiles != snap.legacyFiles { legacyFiles = snap.legacyFiles }
        for line in snap.newLogs { addLog(line.message, isError: line.isError) }
    }

    var sortedSessions: [SessionSnapshot] { sessions }
    var sortedLegacyFiles: [LegacyFileSnapshot] { legacyFiles }

    // MARK: - 日志

    func addLog(_ message: String, isError: Bool = false) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: Date())
        let entry = LogEntry(timestamp: Date(), message: "[\(timeStr)] \(message)", isError: isError)
        logs.append(entry)
        if logs.count > 500 { logs.removeFirst(100) }
    }

    // MARK: - 投喂

    /// 相机回调直接调用，不经主线程。识别出的载荷丢进 actor 就返回
    nonisolated func submit(_ payloads: [Data]) {
        Task { [engine] in await engine.process(payloads) }
    }

    // MARK: - 用户操作

    func startFinalize(_ session: SessionSnapshot) {
        Task { [engine] in await engine.startFinalize(session.sessionId) }
    }

    func cancelFinalize(_ session: SessionSnapshot) {
        Task { [engine] in await engine.cancelFinalize(session.sessionId) }
    }

    /// 刷盘现在是异步的，而调用它的时机多半正是「要进后台了」。
    /// 不申请后台任务的话，主线程可能在这个 Task 跑起来之前就被挂起，这次保存直接不发生。
    func saveAllProgress(force: Bool) {
        let token = UIApplication.shared.beginBackgroundTask(withName: "qrdrop.saveProgress")
        Task { [engine] in
            await engine.saveAllProgress(force: force)
            await self.refresh()
            if token != .invalid { UIApplication.shared.endBackgroundTask(token) }
        }
    }

    func clearAll() {
        Task { [engine] in
            await engine.clearAll()
            await self.refresh()
        }
    }

    func encodeProgress() async -> Data {
        await engine.encodeProgress()
    }

    func loadProgress(from data: Data) {
        Task { [engine] in
            do {
                try await engine.loadProgress(from: data)
            } catch {
                self.addLog("导入进度失败：\(error.localizedDescription)", isError: true)
            }
            await self.refresh()
        }
    }

    func assembleLegacy(_ file: LegacyFileSnapshot) async -> (fileName: String, data: Data)? {
        await engine.assembleLegacy(fileId: file.fileId)
    }

    // MARK: - 从图片识别（照片导入）

    /// 识别与解码都不放主线程：Vision / CIDetector 对一张大图的推理是几十到几百毫秒
    @discardableResult
    func processImage(_ cgImage: CGImage) async -> Bool {
        let useVision = selectedEngine == .vision
        let payloads = await Task.detached(priority: .userInitiated) { () -> [Data] in
            useVision ? FileReceiver.payloadsWithVision(cgImage)
                      : FileReceiver.payloadsWithCIDetector(cgImage)
        }.value
        guard !payloads.isEmpty else {
            addLog("图片中未识别出可用的二维码", isError: true)
            return false
        }
        let gained = await engine.process(payloads)
        await refresh()
        return gained
    }

    private nonisolated static func payloadsWithCIDetector(_ cgImage: CGImage) -> [Data] {
        let ciImage = CIImage(cgImage: cgImage)
        let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                  context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        guard let features = detector?.features(in: ciImage) as? [CIQRCodeFeature] else { return [] }
        // CIQRCodeFeature.symbolDescriptor（iOS 11 起）同样给出原始数据码字，
        // messageString 在二进制载荷下为 nil 并不代表取不到字节
        return features.compactMap {
            rawPayload(descriptor: $0.symbolDescriptor, fallbackString: $0.messageString)
        }
    }

    private nonisolated static func payloadsWithVision(_ cgImage: CGImage) -> [Data] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .filter { $0.symbology == .qr }
            .compactMap { rawPayload(of: $0) }
    }

    // MARK: - 原始载荷提取

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
}
