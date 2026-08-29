//
//  CameraScannerView.swift
//  QrDrop
//
//  扫描页。全屏取景 + 取景框引导 + 一张进度卡。
//
//  旧版把八九个工程读数平铺在半透明面板里，扫描时既看不过来也帮不上忙。
//  这里默认只留「在收哪个文件、收到百分之多少、还要多久」，识别帧率、送检帧率、
//  帧数与块数折进可展开的一行，需要标定识别率时再打开。
//

import SwiftUI
import AVFoundation
import Combine
import Vision
import QuartzCore
import UIKit

struct CameraScannerView: View {
    @ObservedObject var receiver: FileReceiver
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = CameraScanner()

    /// 接收速率与识别帧率，窗口均为最近 1 秒
    @State private var rate: Double = 0
    @State private var detectedFps: Double = 0
    @State private var processedFps: Double = 0
    @State private var showTechnical = false

    /// 速率需要在没有新帧时也归零，因此单独定时刷新，不能只靠 receiver 的变更驱动。
    ///
    /// 必须用 @State 持有：写成 let 属性时，View 结构体每次重建都会新建一个 publisher，
    /// onReceive 随之退订重订、0.25 秒倒计时被反复重置。扫描时会话快照每 100ms 换一次、
    /// body 重建远快于 0.25 秒，结果是读数几乎不刷新。
    @State private var rateTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    /// 仍在接收的会话，已完成的不在扫描界面显示进度
    private var activeSessions: [SessionSnapshot] {
        receiver.sortedSessions.filter { !$0.isComplete }
    }

    /// 当前重点关注的会话：取最后一个仍在接收的。多文件并行时其余的折在下面一行
    private var primary: SessionSnapshot? { activeSessions.last }

    /// 已收齐或已完成的会话数，只用一行汇总
    private var settledCount: Int {
        receiver.sortedSessions.filter(\.isComplete).count
    }

    // 以下计数只统计仍在接收的会话：已完成的文件不该继续占着摄像头界面的读数，
    // 否则数字停在几万不动，看不出当前到底在收什么。

    private var totalFramesAccepted: Int {
        activeSessions.reduce(0) { $0 + $1.stats.framesAccepted }
    }

    private var totalBlocksReceived: Int {
        activeSessions.reduce(0) { $0 + $1.stats.blocksUnique }
    }

    private var totalBlocksSolved: Int {
        activeSessions.reduce(0) { $0 + $1.solvedCount }
    }

    /// 送检帧率读数。Vision 是实测值；AVFoundation 拿不到分母，
    /// 但它管线内每帧都送检，等于相机设定帧率
    private var processedFpsText: String {
        scanner.measuresProcessedFps
            ? ThroughputMeter.formatFps(processedFps)
            : String(format: "%.1f", Double(scanner.effectiveFps))
    }

    var body: some View {
        ZStack {
            CameraPreviewView(session: scanner.session)
                .ignoresSafeArea()

            ViewfinderOverlay()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                statusCard
            }

            CompletionToast(name: $receiver.justCompleted)
                .padding(.top, 60)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .statusBarHidden(false)
        .onAppear {
            scanner.engine = receiver.selectedEngine
            scanner.maxFps = receiver.maxScanFps
            scanner.resolution = receiver.scanResolution
            // 识别结果直接投进解码 actor，不经主线程——喷泉码的雪崩剥离
            // 在大文件上是几百毫秒级的，放主线程会把取景一起冻住
            scanner.onQRCodeDetected = { [weak receiver] payloads in
                receiver?.submit(payloads)
            }
            scanner.start()
            // 扫描是「举着手机盯屏幕」的长任务，自动锁屏会直接打断传输
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            scanner.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            Task { @MainActor in receiver.saveAllProgress(force: true) }
        }
        .onReceive(rateTimer) { _ in
            rate = receiver.throughput.bytesPerSecond()
            detectedFps = scanner.detectedMeter.perSecond()
            processedFps = scanner.processedMeter.perSecond()
        }
    }

    // MARK: - 顶部：关闭、模式、手电筒

    private var topBar: some View {
        HStack {
            Button {
                scanner.stop()
                dismiss()
                // 刷盘在解码 actor 上跑，不挡关闭动画
                receiver.saveAllProgress(force: true)
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("结束扫描")

            Spacer()

            // 把实际生效的参数摆出来：预设名单独出现时，看不出它到底调了什么
            Text("\(receiver.scanPreset.rawValue) · \(receiver.scanResolution.rawValue) · \(receiver.maxScanFps)fps")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.45), in: Capsule())

            Spacer()

            Button {
                scanner.toggleTorch()
            } label: {
                Image(systemName: scanner.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.headline)
                    .foregroundStyle(scanner.isTorchOn ? .yellow : .white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .opacity(scanner.hasTorch ? 1 : 0)
            .disabled(!scanner.hasTorch)
            .accessibilityLabel("手电筒")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - 底部进度卡

    private var statusCard: some View {
        VStack(spacing: 14) {
            if let session = primary {
                receivingBody(session)
            } else {
                idleBody
            }

            if settledCount > 0 {
                Label("已收齐 \(settledCount) 个文件，正在后台还原",
                      systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if activeSessions.count > 1 {
                Text("另有 \(activeSessions.count - 1) 个文件同时接收中")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            technicalRow
        }
        .padding(18)
        // 用固定暗色底而非 ultraThinMaterial：本应用的取景对象恒为
        // 显示白底二维码的屏幕，材质会被映成浅色，白字将不可读
        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var idleBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "viewfinder")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.85))
                .symbolEffect(.pulse)
            Text("把二维码对准取景框")
                .font(.headline)
                .foregroundStyle(.white)
            Text("让二维码尽量填满方框，手机拿稳，识别会自动开始")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func receivingBody(_ session: SessionSnapshot) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.friendlyName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(AppFormat.percent(session.displayProgress))
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(.white)
            }

            ProgressView(value: session.displayProgress)
                .tint(Theme.success)

            HStack(spacing: 8) {
                Text("\(AppFormat.bytes(session.receivedBytesEstimate)) / \(AppFormat.bytes(session.totalBytesEstimate))")
                Text("·")
                Text(ThroughputMeter.format(rate))
                if let eta = AppFormat.eta(remainingBytes: session.remainingBytesEstimate,
                                           bytesPerSecond: rate) {
                    Text("·")
                    Text("剩余 \(eta)")
                }
                Spacer(minLength: 0)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    // MARK: - 技术读数（默认收起）

    private var technicalRow: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showTechnical.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                    // 两个读数含义不同，必须都标全：分母是相机送进识别器的帧，
                    // 分子是真正解出二维码的帧，比值才是识别率
                    Text("解码 \(ThroughputMeter.formatFps(detectedFps)) / 送检 \(processedFpsText) fps")
                    Spacer()
                    Image(systemName: showTechnical ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            }

            if showTechnical {
                VStack(spacing: 6) {
                    techLine(scanner.measuresProcessedFps ? "送检帧率（实测）" : "送检帧率（相机设定）",
                             "\(processedFpsText) fps")
                    techLine("解码成功帧率", "\(ThroughputMeter.formatFps(detectedFps)) fps")
                    if scanner.effectiveFps < receiver.maxScanFps {
                        // AV 检测器封顶 30/s，设更高只是空转，这里明说已经压回去了
                        techLine("相机帧率", "\(scanner.effectiveFps) fps（已从 \(receiver.maxScanFps) 压低）")
                    }
                    techLine("已接受帧", "\(totalFramesAccepted)")
                    // 喷泉码下「帧」不是有意义的计量单位：换档会改变每帧块数。
                    // 主计量一律用编码块，并列出已解出的源块数。
                    techLine("编码块 / 已解源块", "\(totalBlocksReceived) / \(totalBlocksSolved)")
                    if let session = primary {
                        let framePayload = session.blocksPerFrame * session.T
                        // 净速率的理论上限：解码成功帧率 x 单帧净载荷。
                        // 实测速率只统计去重后的新块，所以它与上限的差额就是重复帧的占比，
                        // 差得多说明同一个二维码被扫到了不止一次（发送端实际显示帧率偏低）
                        techLine("单帧净载荷", "\(session.blocksPerFrame) × \(session.T) = \(framePayload) B")
                        techLine("净速率上限", ThroughputMeter.format(detectedFps * Double(framePayload)))
                        techLine("重复块比例", session.stats.blocksReceived > 0
                                 ? String(format: "%.0f%%",
                                          Double(session.stats.blocksDuplicate)
                                          / Double(session.stats.blocksReceived) * 100)
                                 : "—")
                        techLine("单帧成功率",
                                 String(format: "%.1f%%",
                                        session.stats.estimatedFrameSuccessRate(
                                            blocksPerFrame: session.blocksPerFrame) * 100))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }

    private func techLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
    }
}

// MARK: - 取景框

/// 四角括号 + 周围压暗。作用是告诉用户「二维码该放这儿、该有多大」——
/// 实际识别范围仍是整幅画面，这里纯粹是取景引导。
struct ViewfinderOverlay: View {
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width * 0.82, geo.size.height * 0.52)
            let rect = CGRect(x: (geo.size.width - side) / 2,
                              y: (geo.size.height - side) / 2 - geo.size.height * 0.06,
                              width: side, height: side)

            ZStack {
                // 挖空取景区：偶奇填充规则让内框成为透明窗口
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRoundedRect(in: rect, cornerSize: CGSize(width: 24, height: 24))
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))

                CornerBrackets()
                    .stroke(Color.white.opacity(pulse ? 0.95 : 0.55), style: .init(lineWidth: 3, lineCap: .round))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// 四个直角括号，长度取边长的 18%
struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let len = min(rect.width, rect.height) * 0.18

        p.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))

        p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))

        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))

        p.move(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))

        return p
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

    /// 手电筒状态。发送端屏幕本身发光，多数场景用不上，
    /// 但对着反光屏幕或昏暗环境时偶尔有用，故保留一个开关
    @Published private(set) var isTorchOn = false
    @Published private(set) var hasTorch = false

    /// 送检帧率：真正交给识别器的帧数。只有 Vision 路径能实测——它的限流在我们手里。
    /// AVFoundation 在采集管线内部检测，没有「送检了但没扫到码」的回调，
    /// 但它每一帧都会被送检，所以那一档的送检帧率就等于相机设定帧率，直接取设定值即可。
    let processedMeter = ThroughputMeter()
    /// 解码成功帧率：真正解出至少一个二维码的帧数。两种引擎都能统计。
    let detectedMeter = ThroughputMeter()

    /// 送检帧率是实测值还是相机设定值，决定界面怎么标注这个读数
    var measuresProcessedFps: Bool { engine == .vision }

    /// 相机实际帧率。
    ///
    /// AVFoundation 的二维码检测跑在采集管线内部，实测封顶约 30 次/秒：给它 60fps 的
    /// 相机，检出数一帧不涨，只是把电白烧掉。所以那一档主动压到 30。
    var effectiveFps: Int { engine == .avFoundation ? min(maxFps, 30) : maxFps }

    private let metadataOutput = AVCaptureMetadataOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    /// 识别处理队列。Vision 推理与 AVFoundation 元数据回调都走它——两个引擎在
    /// configureSession 里二选一，不会并发，因此 deliver 与其去重表仍是单线程访问。
    ///
    /// 推理必须留在这条代理回调队列上同步跑，不能派到并发队列去并行：
    /// CMSampleBufferGetImageBuffer 拿到的像素缓冲归采集池所有，池子只有几个槽位。
    /// 回调一返回缓冲才还回去；持有到异步推理结束会把池子占空，
    /// alwaysDiscardsLateVideoFrames 下相机随即停止投帧，识别帧率直接掉到 0。
    /// 另外同步阻塞还有个好处：推理一结束下一帧立刻到，周期就是推理耗时本身；
    /// 异步版本要等下一个相机帧边界，周期被向上取整到帧间隔的整数倍，反而更慢。
    private let visionQueue = DispatchQueue(label: "qr.detect.queue", qos: .userInitiated)
    private var isRunning = false
    private var isProcessingVisionFrame = false
    /// 已交付过的载荷哈希，避免同一帧被反复解析
    private var recentPayloadHashes = Set<Int>()
    /// 当前使用的采集设备，手电筒开关要用
    private var captureDevice: AVCaptureDevice?

    /** 帧间最小间隔，由 effectiveFps 推导；保护 Vision ML 不被硬件帧率压垮 */
    private var minFrameInterval: CFTimeInterval = 1.0 / 20.0
    private var lastFrameProcessedAt: CFTimeInterval = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // 锁定本次会话使用的帧间隔，避免运行中被改动。
        // 留 10% 余量：相机已经按 effectiveFps 限帧，两处卡同一个数时，采集抖动会让
        // 间隔偶尔差几十微秒不达标而白丢一帧，读数于是恒低于设定值
        minFrameInterval = 0.9 / Double(max(1, effectiveFps))
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
        setTorch(on: false)
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    // MARK: - 手电筒

    func toggleTorch() { setTorch(on: !isTorchOn) }

    private func setTorch(on: Bool) {
        guard let device = captureDevice, device.hasTorch else { return }
        sessionQueue.async { [weak self] in
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            guard let self else { return }
            Task { @MainActor in self.isTorchOn = on }
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
        captureDevice = device
        let torchAvailable = device.hasTorch
        Task { @MainActor in self.hasTorch = torchAvailable }

        applyFrameRate(on: device)

        if device.isFocusModeSupported(.continuousAutoFocus) {
            try? device.lockForConfiguration()
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        }

        switch engine {
        case .avFoundation:
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: visionQueue)
                metadataOutput.metadataObjectTypes = [.qr]
            }
            // 这里曾经再挂一路只做计数的 videoDataOutput 来测送检帧率。
            // 撤掉了：同一采集会话挂两路 output 有可能压低 metadata 的产出频率，
            // 而它换来的读数本就等于相机设定帧率（管线内每帧都送检），信息量近乎为零。
            // 拿一个可能拖慢识别的副作用去换一个能直接算出来的数，不划算。
        case .vision:
            videoDataOutput.setSampleBufferDelegate(self, queue: visionQueue)
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
            }
        }

        session.commitConfiguration()
    }

    /// 把相机的输出帧率**上限**压到 maxFps。
    ///
    /// 两件事：
    /// 1. 目标帧率超过 30 时换 activeFormat——sessionPreset 隐含 30fps 上限，不换格式上不去。
    ///    采样混叠模型 N = D x fps / 1000 >= 2.5：30fps 时显示间隔不能低于 83ms，
    ///    60fps 则可压到 42ms，发送端吞吐直接翻倍。
    /// 2. 只设 activeVideoMinFrameDuration（它限的是帧率上限），不设 MaxFrameDuration。
    ///
    /// 第 2 点是关键，两边都钉死会出事：相机变成严格周期采样，与同样严格周期的发送端
    /// 构成固定相位。比值落在 1.0 这种整数比上时，如果那个相位恰好压在显示切换的瞬间，
    /// 每一帧曝光都跨着两个二维码，拍到的全是叠影——识别率稳定为 0，而且自己恢复不了，
    /// 只有暂停重放把相位打乱才能重新开始。留着 MaxFrameDuration 不管，自动曝光会让
    /// 帧时长自然浮动，相位持续漂移，坏相位最多持续一小段而不会锁死。
    private func applyFrameRate(on device: AVCaptureDevice) {
        let maxFps = effectiveFps
        if maxFps > 30 {
            let want = (resolution == .hd720p) ? (1280, 720) : (1920, 1080)
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
            if let format = best, (try? device.lockForConfiguration()) != nil {
                device.activeFormat = format
                device.unlockForConfiguration()
            }
        }

        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        // 目标帧间隔必须落在当前格式支持的区间内，越界会直接抛异常
        let wanted = CMTime(value: 1, timescale: CMTimeScale(max(1, maxFps)))
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard let range = ranges.first else { return }
        let duration = CMTimeMaximum(CMTimeMinimum(wanted, range.maxFrameDuration), range.minFrameDuration)
        // 先把下限放开再设上限：AVCaptureDevice 是全设备共享的单例，上一次扫描留下的
        // MaxFrameDuration 会跟着活到这一次，不显式复位就等于没改
        device.activeVideoMaxFrameDuration = range.maxFrameDuration
        device.activeVideoMinFrameDuration = duration
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
