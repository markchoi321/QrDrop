//
//  ContentView.swift
//  QrDrop
//
//  Created by Victor on 2026/2/21.
//

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var receiver = FileReceiver()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showLoadPicker = false
    @State private var showClearConfirm = false
    @State private var expandedSessionId: UInt32?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                enginePicker

                scanSettings

                controlSection

                Divider()

                if receiver.sessions.isEmpty && receiver.legacyFiles.isEmpty {
                    emptyStateView
                } else {
                    fileListSection
                }

                Divider()

                logSection
            }
            .sheet(isPresented: $showCamera) {
                CameraScannerView(receiver: receiver)
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoImportView(receiver: receiver)
            }
            .sheet(isPresented: $showLoadPicker) {
                DocumentPickerView(receiver: receiver)
            }
            .onChange(of: scenePhase) { _, phase in
                // 进入后台立即全量保存，设计 9.3
                if phase != .active { receiver.saveAllProgress(force: true) }
            }
        }
    }

    // MARK: - 引擎选择器

    private var enginePicker: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text("识别引擎")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("识别引擎", selection: $receiver.selectedEngine) {
                    ForEach(QREngine.allCases) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
            }

            Text(receiver.selectedEngine == .avFoundation
                 ? "AVFoundation 在采集管线内检测，功耗低、更适合高帧率"
                 : "Vision 逐帧推理，识别率通常更高，但更吃电与发热")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: - 扫描设置（仅在启动扫描前生效）

    private var scanSettings: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("分辨率")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("分辨率", selection: $receiver.scanResolution) {
                    ForEach(ScanResolution.allCases) { res in
                        Text(res.rawValue).tag(res)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 12) {
                Text("帧率")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 5…60fps，每档 5fps。超过 30 需显式选 activeFormat，见 CameraScanner
                Slider(
                    value: Binding(
                        get: { Double(receiver.maxScanFps) },
                        set: { receiver.maxScanFps = Int($0) }
                    ),
                    in: 5...60,
                    step: 5
                )

                Text("\(receiver.maxScanFps) fps")
                    .font(.caption.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }

            // 采样混叠模型：每个二维码的期望扫描次数 N = 间隔 x 帧率 / 1000，经验阈值 2.5
            Text(scanRateHint)
                .font(.caption2)
                .foregroundStyle(receiver.maxScanFps > 30 ? .orange : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    /// 由帧率推出发送端可用的最短显示间隔，并在高帧率下提示发热
    private var scanRateHint: String {
        let minInterval = Int((2.5 / Double(receiver.maxScanFps) * 1000).rounded(.up))
        let base = "发送端显示间隔建议不低于 \(minInterval) ms（N = 间隔 × 帧率 / 1000 ≥ 2.5）"
        if receiver.maxScanFps > 30 {
            return base + "；超过 30fps 需相机支持高帧率格式，发热明显上升，建议配合 AVFoundation 引擎"
        }
        return base
    }

    // MARK: - 操作区

    private var controlSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    showCamera = true
                } label: {
                    Label("摄像头扫描", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showPhotoPicker = true
                } label: {
                    Label("导入图片", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }

            HStack(spacing: 12) {
                Button {
                    exportProgress()
                } label: {
                    Label("导出进度", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showLoadPicker = true
                } label: {
                    Label("导入进度", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清理", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .confirmationDialog("清空全部接收数据？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                    Button("清空", role: .destructive) { receiver.clearAll() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("会话列表、传输进度与已接收的文件都会被删除，不可恢复。请先导出需要保留的文件。")
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("暂无接收会话")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("请启动摄像头扫描或导入二维码图片")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 会话列表

    private var fileListSection: some View {
        List {
            ForEach(receiver.sortedSessions) { session in
                SessionProgressSection(
                    session: session,
                    revision: receiver.revision,
                    isExpanded: expandedSessionId == session.sessionId,
                    onTap: {
                        withAnimation {
                            expandedSessionId = expandedSessionId == session.sessionId ? nil : session.sessionId
                        }
                    },
                    onExport: { exportSession(session, viaShareSheet: false) },
                    onShare: { exportSession(session, viaShareSheet: true) },
                    onCancelFinalize: { receiver.cancelFinalize(session) },
                    onStartFinalize: { receiver.startFinalize(session) }
                )
            }

            ForEach(receiver.sortedLegacyFiles) { file in
                LegacyFileSection(file: file,
                                  revision: receiver.revision,
                                  onExport: { exportLegacy(file) })
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 日志

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("日志")
                    .font(.headline)
                Spacer()
                Button("清空") {
                    receiver.logs.removeAll()
                }
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(receiver.logs) { log in
                            Text(log.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(log.isError ? .red : .primary)
                                .id(log.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 120)
                .onChange(of: receiver.logs.count) { _, _ in
                    if let last = receiver.logs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - 操作方法

    private func exportProgress() {
        do {
            let data = try receiver.encodeProgress()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("qrdrop_\(Int(Date().timeIntervalSince1970)).vdpg")
            try data.write(to: tempURL)
            receiver.addLog("进度已准备导出（\(data.count) 字节）")
            share(tempURL)
        } catch {
            receiver.addLog("导出进度失败: \(error.localizedDescription)", isError: true)
        }
    }

    private func exportSession(_ session: ReceiveSession, viaShareSheet: Bool) {
        guard let url = session.savedFileURL else {
            receiver.addLog("会话尚未合并，无法导出文件", isError: true)
            return
        }
        viaShareSheet ? share(url) : saveToFiles(url)
    }

    /// 保存到「文件」App。首选路径：不枚举分享扩展、不生成预览，冷启动远快于分享面板
    private func saveToFiles(_ url: URL) {
        let started = Date()
        receiver.addLog("准备保存到文件 \(url.lastPathComponent)，\(Diagnostics.memoryTag())")
        let ok = FileExport.saveToFiles(url: url, onPresented: {
            receiver.addLog("文件选择器已呈现，耗时 \(Diagnostics.elapsedMs(since: started)) ms")
        }, onFinish: { saved in
            receiver.addLog(saved ? "已保存到文件" : "已取消保存")
        })
        if !ok { receiver.addLog("找不到可呈现的窗口", isError: true) }
    }

    /// 系统分享面板。真机首次呈现可能要十秒以上，代价在系统侧，故列为次选
    private func share(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        let started = Date()
        receiver.addLog("准备分享 \(url.lastPathComponent)（\(size) 字节），\(Diagnostics.memoryTag())")
        let ok = FileExport.share(url: url) {
            receiver.addLog("分享面板已呈现，耗时 \(Diagnostics.elapsedMs(since: started)) ms")
        }
        if !ok { receiver.addLog("找不到可呈现分享面板的窗口", isError: true) }
    }

    private func exportLegacy(_ file: LegacyFile) {
        var fileData = Data()
        for i in 0..<file.totalChunks {
            if let chunk = file.chunks[i] { fileData.append(chunk) }
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.fileName)
        do {
            try fileData.write(to: tempURL)
            receiver.addLog("旧格式文件已导出: \(file.fileName)（\(fileData.count) 字节）")
            share(tempURL)
        } catch {
            receiver.addLog("导出失败: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - 会话进度 Section

struct SessionProgressSection: View {
    let session: ReceiveSession
    /// 仅用于触发重绘，ReceiveSession 是引用类型，SwiftUI 无法感知其内部变化
    let revision: Int
    let isExpanded: Bool
    let onTap: () -> Void
    let onExport: () -> Void
    let onShare: () -> Void
    let onCancelFinalize: () -> Void
    let onStartFinalize: () -> Void

    var body: some View {
        Section {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                        Text(session.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }

                    // 主进度：已接收编码块 / 预计所需（设计 12.2）
                    ProgressView(value: session.blockProgress)
                        .tint(statusColor)

                    Text("编码块 \(session.stats.blocksUnique)/\(session.estimatedNeededBlocks)（\(Int(session.blockProgress * 100))%）")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    // 次要指标：源块解出比例
                    Text("源块 \(session.decoder.solvedCount)/\(session.K)（\(Int(session.sourceProgress * 100))%）")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                detailRows

                if session.isFinalizing {
                    VStack(spacing: 6) {
                        // 拼接是 O(K^2) 的回代，大文件可能要跑一会儿，给进度也给退路
                        ProgressView(value: session.finalizeProgress)
                        Text(String(format: "正在合并并校验… %.0f%%", session.finalizeProgress * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button(role: .destructive, action: onCancelFinalize) {
                            Label("停止合并", systemImage: "stop.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                } else if session.isComplete && !session.isFinished {
                    // 块已收齐，合并由用户手动触发；合并完成后才出现导出按钮
                    VStack(spacing: 6) {
                        Text(session.failureMessage == nil
                             ? "已收齐 \(session.K) 个源块，尚未合并成文件"
                             : "上次合并未完成：\(session.failureMessage!)")
                            .font(.caption)
                            .foregroundStyle(session.failureMessage == nil ? Color.secondary : Color.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: onStartFinalize) {
                            Label(session.failureMessage == nil ? "合并文件" : "重新合并",
                                  systemImage: "square.stack.3d.down.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                } else if session.savedFileURL != nil {
                    // 两条导出路径的首次呈现代价都在系统侧，快慢因机而异，
                    // 两个都留着，日志会记录各自的实际耗时
                    Button(action: onExport) {
                        Label("保存到文件", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button(action: onShare) {
                        Label("分享…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var statusIcon: String {
        if session.failureMessage != nil { return "exclamationmark.triangle.fill" }
        if session.isFinalizing { return "hourglass" }
        if session.isFinished { return "checkmark.circle.fill" }
        // 收齐但未合并：用「待处理」而不是对勾，免得看着像已经能导出了
        return session.isComplete ? "shippingbox.circle.fill" : "doc.circle"
    }

    private var statusColor: Color {
        if session.failureMessage != nil { return .red }
        if session.isFinished { return .green }
        return session.isComplete ? .orange : .blue
    }

    @ViewBuilder
    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            infoRow("会话", SessionId.hex(session.sessionId))
            infoRow("参数", "K=\(session.K) · T=\(session.T) · \(session.codec.displayName) · m=\(session.blocksPerFrame)")
            infoRow("冗余系数 ε", String(format: "%.2f%%", session.epsilon * 100))
            infoRow("压缩", session.compressed ? "是" : "否")
            if let meta = session.meta {
                infoRow("原始大小", "\(meta.originalSize) 字节")
            }
            infoRow("帧 通过/拒绝", "\(session.stats.framesAccepted) / \(session.stats.framesRejected)")
            infoRow("块 收到/重复", "\(session.stats.blocksReceived) / \(session.stats.blocksDuplicate)")
            infoRow("最大块序号", "\(session.stats.maxBlockId)")
            infoRow("估算单帧成功率",
                    String(format: "%.1f%%",
                           session.stats.estimatedFrameSuccessRate(blocksPerFrame: session.blocksPerFrame) * 100))
            if let failure = session.failureMessage {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption2, design: .monospaced))
        }
    }
}

// MARK: - 旧格式文件 Section

struct LegacyFileSection: View {
    let file: LegacyFile
    let revision: Int
    let onExport: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: file.isComplete ? "checkmark.circle.fill" : "doc.circle")
                        .foregroundStyle(file.isComplete ? .green : .blue)
                    Text("[旧格式] \(file.fileName)")
                        .font(.headline)
                        .lineLimit(1)
                }
                ProgressView(value: Double(file.chunks.count), total: Double(max(1, file.totalChunks)))
                Text("\(file.chunks.count)/\(file.totalChunks) 片段")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button(action: onExport) {
                    Label(file.isComplete ? "导出文件" : "导出文件（不完整）",
                          systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(file.isComplete ? .green : .orange)
            }
        }
    }
}

// MARK: - Activity View (Share Sheet)

#Preview {
    ContentView()
}
