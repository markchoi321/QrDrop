//
//  CameraScannerView.swift
//  QrBinary
//
//  Created by Victor on 2026/2/21.
//

import SwiftUI
import AVFoundation
import Combine
import Vision
import QuartzCore

struct CameraScannerView: View {
    @ObservedObject var receiver: FileReceiver
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = CameraScanner()

    @State private var lastReceivedInfo: String = ""
    /// 接收速率与识别帧率，窗口均为最近 1 秒
    @State private var rate: Double = 0
    @State private var detectedFps: Double = 0
    @State private var processedFps: Double = 0

    /// 速率需要在没有新帧时也归零，因此单独定时刷新，不能只靠 receiver 的变更驱动。
    ///
    /// 必须用 @State 持有：写成 let 属性时，View 结构体每次重建都会新建一个 publisher，
    /// onReceive 随之退订重订、0.25 秒倒计时被反复重置。扫描时 revision 每帧都在变、
    /// body 重建远快于 0.25 秒，结果是读数几乎不刷新。
    @State private var rateTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    /// 仍在接收的会话，已完成的不在扫描界面显示进度
    private var activeSessions: [ReceiveSession] {
        receiver.sortedSessions.filter { !$0.isComplete }
    }

    /// 已收齐会话的文件名，只用一行汇总，不再显示进度。
    /// 合并是在主界面手动触发的，这里只提示「收齐了」。
    private var completedNames: [String] {
        receiver.sortedSessions.filter(\.isComplete).map(\.displayName)
    }

    // 以下三个计数只统计仍在接收的会话：已完成的文件不该继续占着摄像头界面的读数，
    // 否则数字停在几万不动，看不出当前到底在收什么。

    /// 通过 CRC32 的帧数合计。取自会话统计而非视图本地计数，
    /// 后者在扫描页每次重新打开时归零，会出现「0 帧」与几万块并列的矛盾读数。
    private var totalFramesAccepted: Int {
        activeSessions.reduce(0) { $0 + $1.stats.framesAccepted }
    }

    /// 各会话去重后的编码块合计。这是喷泉码下的主计量单位。
    private var totalBlocksReceived: Int {
        activeSessions.reduce(0) { $0 + $1.stats.blocksUnique }
    }

    /// 各会话已解出的源块合计。BP 解码前期几乎不动、末期雪崩式完成。
    private var totalBlocksSolved: Int {
        activeSessions.reduce(0) { $0 + $1.decoder.solvedCount }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreviewView(session: scanner.session)
                    .ignoresSafeArea()

                VStack {
                    HStack {
                        Label("\(receiver.selectedEngine.rawValue) · \(receiver.scanResolution.rawValue) · \(receiver.maxScanFps)fps",
                              systemImage: receiver.selectedEngine == .vision ? "eye" : "camera.metering.center.weighted")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    Spacer()

                    ScrollView {
                        VStack(spacing: 10) {
                            if !lastReceivedInfo.isEmpty {
                                Text(lastReceivedInfo)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal)
                            }

                            // 喷泉码下「帧」不是有意义的计量单位：换档会改变每帧块数。
                            // 主计量一律用编码块，并列出已解出的源块数。
                            HStack(spacing: 16) {
                                VStack(spacing: 2) {
                                    Text("\(totalBlocksReceived)")
                                        .font(.title3.bold().monospacedDigit())
                                    Text("已接收块")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                VStack(spacing: 2) {
                                    Text("\(totalBlocksSolved)")
                                        .font(.title3.bold().monospacedDigit())
                                    Text("已解码块")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                            .foregroundStyle(.white)

                            // 两个读数互补：帧率含重复识别，反映识别能力本身；
                            // 速率按去重后的编码块字节数计，反映净进度。
                            HStack(spacing: 6) {
                                Image(systemName: "viewfinder")
                                    .font(.caption2)
                                Text("\(ThroughputMeter.formatFps(detectedFps)) fps")
                                if scanner.reportsProcessedFps {
                                    Text("/ 送检 \(ThroughputMeter.formatFps(processedFps))")
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                Text("·")
                                Image(systemName: "speedometer")
                                    .font(.caption2)
                                Text(ThroughputMeter.format(rate))
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.9))

                            Text("已接受 \(totalFramesAccepted) 帧（仅供识别率标定参考）")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.6))

                            // 已完成的会话不再占用进度区：扫描时面板高度有限，
                            // 完成的文件会把仍在接收的挤出可视范围
                            ForEach(activeSessions) { session in
                                sessionRow(session)
                            }

                            if !completedNames.isEmpty {
                                Text("已收齐 \(completedNames.count) 个（回主界面合并）：\(completedNames.joined(separator: "、"))")
                                    .font(.caption2)
                                    .foregroundStyle(.green.opacity(0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal)
                            }

                            ForEach(receiver.sortedLegacyFiles) { file in
                                legacyRow(file)
                            }
                        }
                        .padding()
                    }
                    .frame(maxHeight: 320)
                    // 用固定暗色底而非 ultraThinMaterial：本应用的取景对象恒为
                    // 显示白底二维码的屏幕，材质会被映成浅色，白字将不可读
                    .background(Color.black.opacity(0.62))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
            .navigationTitle("扫描二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        let started = Date()
                        scanner.stop()
                        dismiss()
                        // 保存放到关闭之后，避免序列化挡住关闭动画
                        Task { @MainActor in
                            receiver.saveAllProgress(force: true)
                            let ms = Diagnostics.elapsedMs(since: started)
                            if ms > 300 {
                                receiver.addLog("退出扫描耗时 \(ms) ms，\(Diagnostics.memoryTag())")
                            }
                        }
                    }
                }
            }
            .onAppear {
                scanner.engine = receiver.selectedEngine
                scanner.maxFps = receiver.maxScanFps
                scanner.resolution = receiver.scanResolution
                scanner.onQRCodeDetected = { [weak receiver] payloads in
                    guard let receiver = receiver else { return }
                    Task { @MainActor in
                        for payload in payloads where receiver.processPayload(payload) {
                            // 只反映仍在接收的会话；全部完成时清空，不再显示已完成文件的进度
                            if let session = receiver.sortedSessions.last(where: { !$0.isComplete }) {
                                lastReceivedInfo = "\(session.displayName)  \(session.stats.blocksUnique)/\(session.estimatedNeededBlocks) 块"
                            } else {
                                lastReceivedInfo = ""
                            }
                        }
                    }
                }
                scanner.start()
            }
            .onDisappear {
                scanner.stop()
                Task { @MainActor in receiver.saveAllProgress(force: true) }
            }
            .onReceive(rateTimer) { _ in
                rate = receiver.throughput.bytesPerSecond()
                detectedFps = scanner.detectedMeter.perSecond()
                processedFps = scanner.processedMeter.perSecond()
            }
        }
    }

    // MARK: - 会话进度行（主进度用编码块，次要指标用源块）

    @ViewBuilder
    private func sessionRow(_ session: ReceiveSession) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(session.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("\(session.stats.blocksUnique)/\(session.estimatedNeededBlocks)")
                    .font(.caption.bold().monospacedDigit())
            }
            .foregroundStyle(.white)

            ProgressView(value: session.blockProgress)
                .tint(session.isComplete ? .green : .green.opacity(0.8))

            HStack {
                Text("源块 \(session.decoder.solvedCount)/\(session.K)")
                Spacer()
                Text("\(session.codec.displayName) · T=\(session.T)")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func legacyRow(_ file: LegacyFile) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("[旧] \(file.fileName)")
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text("\(file.chunks.count)/\(file.totalChunks)")
                    .font(.caption.bold().monospacedDigit())
            }
            .foregroundStyle(.white)
            ProgressView(value: Double(file.chunks.count), total: Double(max(1, file.totalChunks)))
                .tint(.blue)
        }
        .padding(.horizontal)
    }
}

// MARK: - Camera Scanner (AVFoundation + Vision)

class CameraScanner: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    /// 回调原始二进制载荷；新协议需要字节而非字符串
    var onQRCodeDetected: (([Data]) -> Void)?
    var engine: QREngine = .vision
    /** 由调用方在 start() 之前设置，决定 Vision 帧处理的最大频率 */
    var maxFps: Int = 20
    /** 由调用方在 start() 之前设置，决定摄像头采集分辨率 */
    var resolution: ScanResolution = .hd1080p

    /// 送检帧率：真正交给识别器的帧数。只有 Vision 路径能统计，
    /// AVFoundation 在采集管线内部检测，不出码时没有任何回调，拿不到分母。
    let processedMeter = ThroughputMeter()
    /// 命中帧率：识别出至少一个二维码的帧数。两种引擎都能统计。
    let detectedMeter = ThroughputMeter()

    /// 送检帧率是否可用，决定界面是否显示该读数
    var reportsProcessedFps: Bool { engine == .vision }

    private let metadataOutput = AVCaptureMetadataOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let visionQueue = DispatchQueue(label: "vision.processing.queue", qos: .userInitiated)
    private var isRunning = false
    private var isProcessingVisionFrame = false
    /// 已交付过的载荷哈希，避免同一帧被反复解析
    private var recentPayloadHashes = Set<Int>()

    /** 帧间最小间隔，由 maxFps 推导；保护 Vision ML 不被 30fps 硬件帧率压垮 */
    private var minFrameInterval: CFTimeInterval = 1.0 / 20.0
    private var lastFrameProcessedAt: CFTimeInterval = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // 锁定本次会话使用的帧间隔，避免运行中被改动
        minFrameInterval = 1.0 / Double(max(1, maxFps))
        processedMeter.reset()
        detectedMeter.reset()

        sessionQueue.async { [weak self] in
            self?.configureSession()
            self?.session.startRunning()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        // 分辨率由用户在扫描前选择；CPU 压力由帧率限制 + 去重短路控制
        session.sessionPreset = (resolution == .hd720p) ? .hd1280x720 : .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        // sessionPreset 隐含 30fps 上限，要突破必须显式选 activeFormat。
        // 采样混叠模型 N = D x fps / 1000 >= 2.5：30fps 时显示间隔不能低于 83ms，
        // 60fps 则可压到 42ms，发送端吞吐直接翻倍。
        applyFormat(on: device)

        if device.isFocusModeSupported(.continuousAutoFocus) {
            try? device.lockForConfiguration()
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        }

        switch engine {
        case .avFoundation:
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                metadataOutput.metadataObjectTypes = [.qr]
            }
        case .vision:
            videoDataOutput.setSampleBufferDelegate(self, queue: visionQueue)
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
            }
        }

        session.commitConfiguration()
    }

    /// 选一个能跑到目标帧率、且分辨率不低于所选档位的格式。
    ///
    /// 只在目标帧率超过 30 时才动 activeFormat：30fps 以内 sessionPreset 已经够用，
    /// 换格式反而可能拿到视场角或画质不同的格式。
    private func applyFormat(on device: AVCaptureDevice) {
        let want = (resolution == .hd720p) ? (1280, 720) : (1920, 1080)
        guard maxFps > 30 else { return }
        let target = Double(maxFps)
        var best: AVCaptureDevice.Format?
        var bestRate = 0.0
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard Int(d.width) == want.0, Int(d.height) == want.1 else { continue }
            let rate = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            // 优先取恰好覆盖目标帧率的最低档，避免选到 240fps 慢动作格式而牺牲画质
            if rate >= target, best == nil || rate < bestRate {
                best = f
                bestRate = rate
            }
        }
        guard let format = best, (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(maxFps))
        if let range = format.videoSupportedFrameRateRanges.first,
           duration >= range.minFrameDuration {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        device.unlockForConfiguration()
    }

    /// 去重短路：同一二维码在连续多帧里被反复识别，重复载荷直接丢掉
    private func deliver(_ payloads: [Data]) {
        let fresh = payloads.filter { recentPayloadHashes.insert($0.hashValue).inserted }
        guard !fresh.isEmpty else { return }
        if recentPayloadHashes.count > 4096 { recentPayloadHashes.removeAll(keepingCapacity: true) }
        onQRCodeDetected?(fresh)
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate (AVFoundation)

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        // AVMetadataMachineReadableCodeObject.descriptor（iOS 11 起）给的是
        // CIQRCodeDescriptor，即原始数据码字，同样能取出二进制。
        // stringValue 在二进制载荷下恒为 nil，但那不代表拿不到字节。
        let payloads = metadataObjects.compactMap { obj -> Data? in
            guard let readableObj = obj as? AVMetadataMachineReadableCodeObject,
                  readableObj.type == .qr else { return nil }
            return FileReceiver.rawPayload(descriptor: readableObj.descriptor as? CIQRCodeDescriptor,
                                           fallbackString: readableObj.stringValue)
        }
        if !payloads.isEmpty {
            detectedMeter.record()
            deliver(payloads)
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Vision)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !isProcessingVisionFrame else { return }

        let now = CACurrentMediaTime()
        if now - lastFrameProcessedAt < minFrameInterval { return }
        lastFrameProcessedAt = now

        isProcessingVisionFrame = true

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            isProcessingVisionFrame = false
            return
        }

        // 通过限流、确实要跑推理的帧才计入送检；被 minFrameInterval 或
        // isProcessingVisionFrame 挡掉的帧不算，否则读数恒等于相机硬件帧率
        processedMeter.record()

        let request = VNDetectBarcodesRequest { [weak self] request, error in
            defer { self?.isProcessingVisionFrame = false }
            guard let results = request.results as? [VNBarcodeObservation] else { return }
            let payloads = results.compactMap { observation -> Data? in
                guard observation.symbology == .qr else { return nil }
                return FileReceiver.rawPayload(of: observation)
            }
            if !payloads.isEmpty {
                self?.detectedMeter.record()
                self?.deliver(payloads)
            }
        }
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }
}

// MARK: - Camera Preview UIViewRepresentable

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}

    class CameraPreviewUIView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            previewLayer.videoGravity = .resizeAspectFill
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
