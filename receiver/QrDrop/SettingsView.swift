//
//  SettingsView.swift
//  QrDrop
//
//  设置页。旧版把引擎 / 分辨率 / 帧率三个旋钮和采样混叠公式直接摊在首屏，
//  对绝大多数用户是纯噪声。这里改为三档预设，工程参数收进「自定义」，
//  日志、进度导入导出、清空数据也一并搬进来。
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var receiver: FileReceiver
    @Environment(\.dismiss) private var dismiss

    @State private var showLoadPicker = false
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                scanModeSection

                if receiver.scanPreset == .custom {
                    customSection
                }

                progressSection

                Section {
                    NavigationLink {
                        DiagnosticsLogView(receiver: receiver)
                    } label: {
                        Label("诊断日志", systemImage: "doc.text.magnifyingglass")
                    }
                } footer: {
                    Text("接收异常时把日志发给开发者，可以定位问题。")
                }

                Section {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("清空全部接收数据", systemImage: "trash")
                    }
                } footer: {
                    Text("会话列表、传输进度与已接收的文件都会被删除，且不可恢复。请先保存需要留下的文件。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showLoadPicker) {
                DocumentPickerView(receiver: receiver)
            }
            .confirmationDialog("清空全部接收数据？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) { receiver.clearAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可恢复。")
            }
        }
    }

    // MARK: - 扫描模式

    private var scanModeSection: some View {
        Section {
            ForEach(ScanPreset.allCases) { preset in
                Button {
                    receiver.scanPreset = preset
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: preset.icon)
                            .foregroundStyle(receiver.scanPreset == preset ? Theme.accent : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(preset.rawValue)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                if let summary = preset.summary {
                                    Text(summary)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(preset.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if receiver.scanPreset == preset {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        } header: {
            Text("扫描模式")
        } footer: {
            Text("扫描模式决定摄像头的画质与识别频率。识别不稳、进度长时间不动时，换到「高速」通常会有改善。")
        }
    }

    // MARK: - 自定义参数（工程用法）

    private var customSection: some View {
        Section {
            Picker("识别引擎", selection: $receiver.selectedEngine) {
                ForEach(QREngine.allCases) { engine in
                    Text(engine.rawValue).tag(engine)
                }
            }
            Text(receiver.selectedEngine == .avFoundation
                 ? "AVFoundation 在采集管线内检测，功耗最低；但检测器实测封顶约 30 次/秒，设更高的帧率不会提速"
                 : "Vision 逐帧推理，识别率更高但更吃电；解码帧率取决于单帧推理耗时，降画质比调高帧率更能提速")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("画质", selection: $receiver.scanResolution) {
                ForEach(ScanResolution.allCases) { res in
                    Text(res.rawValue).tag(res)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("扫描频率")
                    Spacer()
                    Text("\(receiver.maxScanFps) fps")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // 5…60fps，每档 5fps。超过 30 需显式选 activeFormat，见 CameraScanner
                Slider(
                    value: Binding(
                        get: { Double(receiver.maxScanFps) },
                        set: { receiver.maxScanFps = Int($0) }
                    ),
                    in: 5...60,
                    step: 5
                )
            }
        } header: {
            Text("自定义参数")
        } footer: {
            // 采样混叠模型：每个二维码的期望扫描次数 N = 间隔 x 帧率 / 1000，经验阈值 2.5
            Text(scanRateHint)
        }
    }

    /// 由帧率推出发送端可用的最短显示间隔，并在高帧率下提示发热
    private var scanRateHint: String {
        let minInterval = Int((2.5 / Double(receiver.maxScanFps) * 1000).rounded(.up))
        let base = "当前频率下，发送端的显示间隔建议不低于 \(minInterval) ms（N = 间隔 × 帧率 / 1000 ≥ 2.5）。"
        if receiver.maxScanFps > 30 {
            return base + "超过 30fps 需相机支持高帧率格式，发热明显上升，建议配合 AVFoundation 引擎。"
        }
        return base
    }

    // MARK: - 进度接力

    private var progressSection: some View {
        Section {
            Button {
                exportProgress()
            } label: {
                Label("导出接收进度", systemImage: "square.and.arrow.up.on.square")
            }
            Button {
                showLoadPicker = true
            } label: {
                Label("导入接收进度", systemImage: "square.and.arrow.down.on.square")
            }
        } header: {
            Text("进度接力")
        } footer: {
            Text("把当前进度导出成一个文件发给另一台设备，对方导入后可以接着扫下去。适合手机快没电、或几台设备分头接收的情况。")
        }
    }

    private func exportProgress() {
        Task {
            do {
                let data = await receiver.encodeProgress()
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("qrdrop_\(Int(Date().timeIntervalSince1970)).vdpg")
                try data.write(to: tempURL)
                receiver.addLog("进度已准备导出（\(data.count) 字节）")
                FileExport.share(url: tempURL)
            } catch {
                receiver.addLog("导出进度失败: \(error.localizedDescription)", isError: true)
            }
        }
    }
}

// MARK: - 诊断日志

struct DiagnosticsLogView: View {
    @ObservedObject var receiver: FileReceiver

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(receiver.logs) { log in
                        Text(log.message)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(log.isError ? Theme.danger : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(log.id)
                    }
                }
                .padding()
            }
            .onChange(of: receiver.logs.count) { _, _ in
                if let last = receiver.logs.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .overlay {
                if receiver.logs.isEmpty {
                    ContentUnavailableView("暂无日志", systemImage: "text.alignleft")
                }
            }
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = receiver.logs.map(\.message).joined(separator: "\n")
                    } label: {
                        Label("拷贝全部", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        receiver.logs.removeAll()
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}
