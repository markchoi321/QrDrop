//
//  ContentView.swift
//  QrBinary
//
//  Created by Victor on 2026/2/21.
//

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var receiver = FileReceiver()
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showLoadPicker = false
    @State private var exportFileURL: URL?
    @State private var showShareSheet = false
    @State private var selectedFileId: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                enginePicker

                controlSection

                Divider()

                if receiver.fileInfo.isEmpty {
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
            .sheet(isPresented: $showShareSheet) {
                if let url = exportFileURL {
                    ActivityView(activityItems: [url])
                }
            }
        }
    }

    // MARK: - 引擎选择器

    private var enginePicker: some View {
        VStack(spacing: 12) {
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
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 12)
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
                    saveProgress()
                } label: {
                    Label("保存进度", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showLoadPicker = true
                } label: {
                    Label("加载进度", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
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
            Text("暂无接收文件")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("请启动摄像头扫描或导入二维码图片")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 文件列表

    private var fileListSection: some View {
        List {
            ForEach(Array(receiver.fileInfo.keys.sorted()), id: \.self) { fileId in
                FileProgressSection(
                    fileId: fileId,
                    receiver: receiver,
                    onExport: { exportFile(fileId: fileId) },
                    isExpanded: selectedFileId == fileId,
                    onTap: {
                        withAnimation {
                            selectedFileId = selectedFileId == fileId ? nil : fileId
                        }
                    }
                )
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

    private func saveProgress() {
        do {
            let data = try receiver.encodeProgress()
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("qr_progress_\(Int(Date().timeIntervalSince1970)).qrprogress")
            try data.write(to: tempURL)
            exportFileURL = tempURL
            showShareSheet = true
            receiver.addLog("进度已准备导出")
        } catch {
            receiver.addLog("保存失败: \(error.localizedDescription)", isError: true)
        }
    }

    private func exportFile(fileId: String) {
        guard let info = receiver.fileInfo[fileId] else { return }
        let total = info.totalChunks

        var fileData = Data()
        var missingCount = 0
        for i in 0..<total {
            if let chunk = receiver.files[fileId]?[i] {
                fileData.append(chunk)
            } else {
                fileData.append(Data(repeating: 0, count: 600))
                missingCount += 1
            }
        }

        if missingCount > 0 {
            receiver.addLog("⚠️ 文件有 \(missingCount) 个缺失片段，已用空字节填充", isError: true)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(info.fileName)

        do {
            try fileData.write(to: tempURL)
            exportFileURL = tempURL
            showShareSheet = true
            receiver.addLog("文件已导出: \(info.fileName) (\(fileData.count) 字节)")
        } catch {
            receiver.addLog("导出失败: \(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - 文件进度 Section

struct FileProgressSection: View {
    let fileId: String
    @ObservedObject var receiver: FileReceiver
    let onExport: () -> Void
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var copiedMissing = false

    var body: some View {
        if let info = receiver.fileInfo[fileId] {
            let received = receiver.files[fileId]?.count ?? 0
            let total = info.totalChunks
            let progress = total > 0 ? Double(received) / Double(total) : 0
            let isComplete = received == total

            Section {
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: isComplete ? "checkmark.circle.fill" : "doc.circle")
                                .foregroundStyle(isComplete ? .green : .blue)
                            Text(info.fileName)
                                .font(.headline)
                            Spacer()
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.secondary)
                        }

                        ProgressView(value: progress)
                            .tint(isComplete ? .green : .blue)

                        Text("\(received)/\(total) 片段 (\(Int(progress * 100))%)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    chunkGridView(total: total, fileId: fileId)

                    missingChunksView(total: total, fileId: fileId)

                    Button {
                        onExport()
                    } label: {
                        Label(isComplete ? "导出文件" : "导出文件（不完整）",
                              systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isComplete ? .green : .orange)
                }
            }
        }
    }

    private func chunkGridView(total: Int, fileId: String) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 2)], spacing: 2) {
                ForEach(0..<total, id: \.self) { index in
                    let hasChunk = receiver.files[fileId]?[index] != nil
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(hasChunk ? Color.green : Color.red.opacity(0.3))
                        Text("\(index + 1)")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(hasChunk ? .white : .red)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    }
                    .frame(height: 22)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxHeight: min(CGFloat((total / 10 + 1) * 24), 220))
        .padding(.vertical, 4)
    }

    private func missingChunksView(total: Int, fileId: String) -> some View {
        let missing = (0..<total).filter { receiver.files[fileId]?[$0] == nil }

        return Group {
            if !missing.isEmpty && missing.count <= 50 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("缺失片段（共 \(missing.count) 个）:")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                        Spacer()
                        Button {
                            let jsonArray = missing.map { $0 + 1 }
                            if let data = try? JSONEncoder().encode(jsonArray),
                               let jsonString = String(data: data, encoding: .utf8) {
                                UIPasteboard.general.string = jsonString
                                copiedMissing = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    copiedMissing = false
                                }
                            }
                        } label: {
                            Label(copiedMissing ? "已复制" : "复制",
                                  systemImage: copiedMissing ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(copiedMissing ? .green : .red)
                    }
                    Text(missing.map { String($0 + 1) }.joined(separator: ", "))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 4)
            } else if !missing.isEmpty {
                HStack {
                    Text("缺失 \(missing.count) 个片段")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    Spacer()
                    Button {
                        let jsonArray = missing.map { $0 + 1 }
                        if let data = try? JSONEncoder().encode(jsonArray),
                           let jsonString = String(data: data, encoding: .utf8) {
                            UIPasteboard.general.string = jsonString
                            copiedMissing = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copiedMissing = false
                            }
                        }
                    } label: {
                        Label(copiedMissing ? "已复制" : "复制",
                              systemImage: copiedMissing ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(copiedMissing ? .green : .red)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Activity View (Share Sheet)

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
