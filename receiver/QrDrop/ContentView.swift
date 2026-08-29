//
//  ContentView.swift
//  QrDrop
//
//  主界面 =「收件箱」。
//
//  设计取向：主流程上只留三样东西——文件列表、一个扫描按钮、完成后的保存。
//  引擎 / 分辨率 / 帧率 / 日志 / 进度导入导出全部退到设置页，因为它们只在
//  出问题或高级用法时才需要，却在旧版里占据了首屏一半的高度。
//

import SwiftUI

struct ContentView: View {
    @StateObject private var receiver = FileReceiver()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showSettings = false
    @State private var detailSession: SessionSnapshot?
    @State private var pendingDelete: DeleteTarget?

    /// 待删除项。删除会同时清掉磁盘上的进度或文件，所以一律先确认
    enum DeleteTarget: Identifiable {
        case session(SessionSnapshot)
        case received(ReceivedFileRecord)
        case legacy(LegacyFileSnapshot)

        var id: String {
            switch self {
            case .session(let s):  return "s\(s.sessionId)"
            case .received(let r): return "r\(r.sessionId)"
            case .legacy(let f):   return "l\(f.fileId)"
            }
        }

        var name: String {
            switch self {
            case .session(let s):  return s.friendlyName
            case .received(let r): return r.fileName
            case .legacy(let f):   return f.fileName
            }
        }

        var message: String {
            switch self {
            case .session:  return "已接收的进度会被删除，之后需要从头重新扫描。"
            case .received: return "文件会从本机删除。如果还没保存或分享出去，删除后无法找回。"
            case .legacy:   return "已接收的片段会被删除，不可恢复。"
            }
        }
    }

    private var isEmpty: Bool {
        receiver.sessions.isEmpty && receiver.legacyFiles.isEmpty && receiver.receivedFiles.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                if isEmpty {
                    welcomeView
                } else {
                    inboxList
                }
            }
            .navigationTitle("接收")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .overlay(alignment: .top) {
                if !showCamera {
                    CompletionToast(name: $receiver.justCompleted)
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraScannerView(receiver: receiver)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoImportView(receiver: receiver)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(receiver: receiver)
        }
        .confirmationDialog(pendingDelete.map { "删除「\($0.name)」？" } ?? "",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                switch pendingDelete {
                case .session(let s):  receiver.deleteSession(s)
                case .received(let r): receiver.deleteReceivedFile(r)
                case .legacy(let f):   receiver.deleteLegacyFile(f)
                case nil: break
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.message ?? "")
        }
        .sheet(item: $detailSession) { session in
            // 详情页要跟着快照刷新（合并进度、最终大小），因此按 id 取当前值而非用旧副本
            SessionDetailView(sessionId: session.sessionId, receiver: receiver)
        }
        .task {
            // 界面不再持有会话对象，改为按固定节拍取不可变快照，
            // 视图消失时 SwiftUI 会自动取消这个 task
            await receiver.runRefreshLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            // 进入后台立即全量保存，设计 9.3
            if phase != .active { receiver.saveAllProgress(force: true) }
        }
    }

    // MARK: - 空状态：把「怎么用」直接写在首屏

    private var welcomeView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 68, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text("用摄像头接收文件")
                        .font(.title2.bold())
                    Text("不需要网络、蓝牙或数据线，\n对准对方屏幕上滚动的二维码即可。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                VStack(alignment: .leading, spacing: 18) {
                    stepRow(1, "在电脑上打开发送端", "选好要传的文件，让二维码开始滚动播放")
                    stepRow(2, "点下方「开始扫描」", "把手机举稳，让二维码填满取景框")
                    stepRow(3, "收齐后自动还原", "文件校验通过后可直接保存或分享")
                }
                .card()
                .padding(.horizontal)

                Text("中途可以随时退出，进度会自动保存，下次接着扫。")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 12)
            }
        }
    }

    private func stepRow(_ index: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(index)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 收件箱

    /// 用 List 而不是 ScrollView：滑动删除是 List 行的原生能力，
    /// 自己在 LazyVStack 上拿手势拼一套等价交互不值当
    private var inboxList: some View {
        List {
            ForEach(receiver.sortedSessions) { session in
                SessionCard(
                    session: session,
                    onRetry: { receiver.startFinalize(session) },
                    onDetail: { detailSession = session }
                )
                .listRow()
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = .session(session)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            ForEach(receiver.receivedFiles) { record in
                ReceivedFileCard(
                    record: record,
                    onSave: { saveToFiles(record.url) },
                    onShare: { share(record.url) }
                )
                .listRow()
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = .received(record)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            ForEach(receiver.sortedLegacyFiles) { file in
                LegacyFileCard(file: file, onExport: { exportLegacy(file) })
                    .listRow()
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = .legacy(file)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }

    // MARK: - 底部主操作

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button {
                showCamera = true
            } label: {
                Label("开始扫描", systemImage: "viewfinder")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                showPhotoPicker = true
            } label: {
                Label("从相册导入二维码图片", systemImage: "photo.on.rectangle")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    // MARK: - 导出

    /// 保存到「文件」App。首选路径：不枚举分享扩展、不生成预览，冷启动远快于分享面板
    private func saveToFiles(_ url: URL?) {
        guard let url else { return }
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
    private func share(_ url: URL?) {
        guard let url else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        let started = Date()
        receiver.addLog("准备分享 \(url.lastPathComponent)（\(size) 字节），\(Diagnostics.memoryTag())")
        let ok = FileExport.share(url: url) {
            receiver.addLog("分享面板已呈现，耗时 \(Diagnostics.elapsedMs(since: started)) ms")
        }
        if !ok { receiver.addLog("找不到可呈现分享面板的窗口", isError: true) }
    }

    private func exportLegacy(_ file: LegacyFileSnapshot) {
        Task {
            guard let assembled = await receiver.assembleLegacy(file) else { return }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(assembled.fileName)
            do {
                try assembled.data.write(to: tempURL)
                receiver.addLog("旧格式文件已导出: \(assembled.fileName)（\(assembled.data.count) 字节）")
                share(tempURL)
            } catch {
                receiver.addLog("导出失败: \(error.localizedDescription)", isError: true)
            }
        }
    }
}

// MARK: - 会话卡片

struct SessionCard: View {
    let session: SessionSnapshot
    let onRetry: () -> Void
    let onDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            progressBar
            actions
        }
        .card()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDetail)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: session.iconName)
                .font(.title2)
                .foregroundStyle(session.accentColor)
                .frame(width: 40, height: 40)
                .background(session.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(session.friendlyName)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(session.hasFileName ? .primary : .secondary)
                Text(session.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if session.phase == .receiving {
                Text(AppFormat.percent(session.displayProgress))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(session.accentColor)
            }
        }
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            ProgressView(value: session.isFinalizing ? session.finalizeProgress : session.displayProgress)
                .progressViewStyle(.linear)
                .tint(session.accentColor)

            if session.isFinalizing {
                Text("正在校验并还原，请勿关闭 App… \(AppFormat.percent(session.finalizeProgress))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch session.phase {
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                if let message = session.failureMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                }
                Button(action: onRetry) {
                    Label("重试还原", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
            }

        case .receiving, .processing, .done:
            EmptyView()
        }
    }
}

// MARK: - 已完成文件卡片

/// 完成的文件来自持久化清单而不是内存里的会话，因此重启后依然在列表里。
/// 会话在合并成功那一刻就被移出接收列表，两者不会同时出现。
struct ReceivedFileCard: View {
    let record: ReceivedFileRecord
    let onSave: () -> Void
    let onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: AppFormat.icon(forFileName: record.fileName))
                    .font(.title2)
                    .foregroundStyle(Theme.success)
                    .frame(width: 40, height: 40)
                    .background(Theme.success.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.fileName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("已完成 · \(AppFormat.bytes(record.size)) · \(Self.dateText(record.receivedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            }

            HStack(spacing: 10) {
                Button(action: onSave) {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.success))

                Button(action: onShare) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .card()
    }

    private static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 旧格式文件卡片

struct LegacyFileCard: View {
    let file: LegacyFileSnapshot
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: file.isComplete ? "checkmark.circle.fill" : "doc")
                    .font(.title2)
                    .foregroundStyle(file.isComplete ? Theme.success : Theme.accent)
                    .frame(width: 40, height: 40)
                    .background((file.isComplete ? Theme.success : Theme.accent).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(file.fileName).font(.headline).lineLimit(1)
                    Text("旧版格式 · \(file.receivedChunks)/\(file.totalChunks) 片段")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !file.isComplete {
                ProgressView(value: file.displayProgress).tint(Theme.accent)
            }

            Button(action: onExport) {
                Label(file.isComplete ? "导出文件" : "导出（不完整）", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle(tint: file.isComplete ? Theme.success : Theme.warning))
        }
        .card()
    }
}

// MARK: - 完成提示

/// 文件还原成功时的一次性横幅。放在扫描页与主页各一份，
/// 谁在前台谁负责消费掉这个信号
struct CompletionToast: View {
    @Binding var name: String?

    var body: some View {
        Group {
            if let name {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("接收完成").font(.subheadline.weight(.semibold))
                        Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: name) {
                    try? await Task.sleep(for: .seconds(2.6))
                    withAnimation { self.name = nil }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: name)
        .sensoryFeedback(.success, trigger: name) { _, new in new != nil }
    }
}

#Preview {
    ContentView()
}
