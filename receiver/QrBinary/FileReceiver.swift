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
import zlib

// MARK: - 识别引擎

enum QREngine: String, CaseIterable, Identifiable {
    case avFoundation = "AVFoundation"
    case vision = "Vision"

    var id: String { rawValue }
}

// MARK: - 扫描分辨率

enum ScanResolution: String, CaseIterable, Identifiable {
    case hd720p = "720p"
    case hd1080p = "1080p"

    var id: String { rawValue }
}

// MARK: - 数据模型

struct QRChunk: Codable, Sendable {
    let fileId: String
    let fileName: String
    let totalChunks: Int
    let chunkIndex: Int
    let data: String  // base64
    let crc32: UInt32
}

struct FileInfo: Codable, Sendable {
    let fileName: String
    let totalChunks: Int
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let isError: Bool
}

// MARK: - 进度存储

struct ProgressData: Codable {
    let files: [String: [String: Data]]
    let fileInfo: [String: FileInfo]
}

// MARK: - FileReceiver

class FileReceiver: ObservableObject {
    @Published var files: [String: [Int: Data]] = [:]
    @Published var fileInfo: [String: FileInfo] = [:]
    @Published var logs: [LogEntry] = []
    @Published var selectedEngine: QREngine = .avFoundation
    /** 扫描最大帧率，5/10/15/20/25/30 六档，默认 20fps */
    @Published var maxScanFps: Int = 20
    /** 摄像头分辨率，默认 1080p */
    @Published var scanResolution: ScanResolution = .hd1080p

    private var lastDecodeTime: [String: Date] = [:]
    // 已成功落盘的 QR payload 原始字符串集合，用于在 JSON 解析之前 O(1) 短路重复帧
    private var confirmedPayloads: Set<String> = []

    // MARK: - 日志

    @MainActor
    func addLog(_ message: String, isError: Bool = false) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: Date())
        let logMessage = "[\(timeStr)] \(message)"
        let entry = LogEntry(timestamp: Date(), message: logMessage, isError: isError)
        logs.append(entry)

        if logs.count > 500 {
            logs.removeFirst(100)
        }
    }

    // MARK: - CRC32 验证

    private func verifyCRC32(data: Data, expected: UInt32) -> Bool {
        let calculated = data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> UInt32 in
            guard let pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            let result = zlib.crc32(0, pointer, UInt32(data.count))
            return UInt32(result & 0xffffffff)
        }
        return calculated == expected
    }

    // MARK: - 处理 QR 码数据

    @MainActor
    func processQRCode(_ decodedString: String) -> Bool {
        // 去重前置：相同 payload 已成功处理过则直接短路，避免 JSON 解析 / base64 / CRC32 全部开销
        if confirmedPayloads.contains(decodedString) {
            return false
        }

        guard let jsonData = decodedString.data(using: .utf8) else { return false }

        do {
            let chunk = try JSONDecoder().decode(QRChunk.self, from: jsonData)
            let fileId = chunk.fileId
            let chunkIndex = chunk.chunkIndex

            let key = "\(fileId)_\(chunkIndex)"
            let now = Date()
            if let lastTime = lastDecodeTime[key], now.timeIntervalSince(lastTime) < 0.5 {
                return false
            }
            lastDecodeTime[key] = now

            if files[fileId]?[chunkIndex] != nil {
                return false
            }

            guard let dataBytes = Data(base64Encoded: chunk.data) else {
                addLog("片段 \(chunkIndex) base64 解码失败", isError: true)
                return false
            }

            if !verifyCRC32(data: dataBytes, expected: chunk.crc32) {
                addLog("⚠️ 片段 \(chunkIndex) CRC32 校验失败", isError: true)
                return false
            }

            if fileInfo[fileId] == nil {
                fileInfo[fileId] = FileInfo(fileName: chunk.fileName, totalChunks: chunk.totalChunks)
            }

            if files[fileId] == nil {
                files[fileId] = [:]
            }
            files[fileId]![chunkIndex] = dataBytes
            confirmedPayloads.insert(decodedString)

            let received = files[fileId]?.count ?? 0
            let total = chunk.totalChunks
            addLog("✓ 片段 \(chunkIndex + 1)/\(total) - \(chunk.fileName)")

            if received == total {
                addLog("🎉 文件 \(chunk.fileName) 接收完成！")
            }

            return true
        } catch {
            return false
        }
    }

    // MARK: - 从图片识别 QR 码（根据引擎选择）

    @MainActor
    func processImage(_ cgImage: CGImage) -> Bool {
        switch selectedEngine {
        case .avFoundation:
            return processImageWithCIDetector(cgImage)
        case .vision:
            return processImageWithVision(cgImage)
        }
    }

    // MARK: - CIDetector 识别

    @MainActor
    private func processImageWithCIDetector(_ cgImage: CGImage) -> Bool {
        let ciImage = CIImage(cgImage: cgImage)
        let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                  context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])

        guard let features = detector?.features(in: ciImage) as? [CIQRCodeFeature] else {
            return false
        }

        var processed = false
        for feature in features {
            if let message = feature.messageString {
                if processQRCode(message) {
                    processed = true
                }
            }
        }
        return processed
    }

    // MARK: - Vision 框架识别

    @MainActor
    private func processImageWithVision(_ cgImage: CGImage) -> Bool {
        var processed = false

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])

            if let results = request.results {
                for result in results {
                    if result.symbology == .qr, let payload = result.payloadStringValue {
                        if processQRCode(payload) {
                            processed = true
                        }
                    }
                }
            }
        } catch {
            addLog("Vision 识别失败: \(error.localizedDescription)", isError: true)
        }

        return processed
    }

    // MARK: - 进度 保存/加载

    func encodeProgress() throws -> Data {
        var stringKeyFiles: [String: [String: Data]] = [:]
        for (fileId, chunks) in files {
            var stringChunks: [String: Data] = [:]
            for (index, data) in chunks {
                stringChunks[String(index)] = data
            }
            stringKeyFiles[fileId] = stringChunks
        }
        let progressData = ProgressData(files: stringKeyFiles, fileInfo: fileInfo)
        return try JSONEncoder().encode(progressData)
    }

    @MainActor
    func loadProgress(from data: Data) throws {
        let progressData = try JSONDecoder().decode(ProgressData.self, from: data)
        var intKeyFiles: [String: [Int: Data]] = [:]
        for (fileId, chunks) in progressData.files {
            var intChunks: [Int: Data] = [:]
            for (indexStr, chunkData) in chunks {
                if let index = Int(indexStr) {
                    intChunks[index] = chunkData
                }
            }
            intKeyFiles[fileId] = intChunks
        }
        self.files = intKeyFiles
        self.fileInfo = progressData.fileInfo
        addLog("进度已加载，包含 \(fileInfo.count) 个文件")
    }

    // MARK: - 清空

    @MainActor
    func clearAll() {
        files.removeAll()
        fileInfo.removeAll()
        lastDecodeTime.removeAll()
        confirmedPayloads.removeAll()
        addLog("数据已清空")
    }
}
