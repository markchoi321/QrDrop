//
//  SessionDetailView.swift
//  QrDrop
//
//  单个会话的详情。普通用户看上半部分（文件、进度、来源），
//  需要排障的人展开「技术细节」拿到全部协议参数与识别统计。
//

import SwiftUI

struct SessionDetailView: View {
    let sessionId: UInt32
    @ObservedObject var receiver: FileReceiver
    @Environment(\.dismiss) private var dismiss

    @State private var showTechnical = false

    /// 始终取当前快照，避免详情页停在打开那一刻的旧数据
    private var session: SessionSnapshot? {
        receiver.sessions.first { $0.sessionId == sessionId }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    content(session)
                } else {
                    // 合并成功的会话会立刻从接收列表移到已完成列表，
                    // 详情页开着的时候完成，就会走到这里
                    ContentUnavailableView("这个文件已经接收完成",
                                           systemImage: "checkmark.circle",
                                           description: Text("返回列表即可保存或分享。"))
                }
            }
            .navigationTitle("文件详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func content(_ session: SessionSnapshot) -> some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: session.iconName)
                        .font(.system(size: 44))
                        .foregroundStyle(session.accentColor)
                    Text(session.friendlyName)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(session.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if session.phase != .done {
                        ProgressView(value: session.isFinalizing ? session.finalizeProgress
                                                                : session.displayProgress)
                            .tint(session.accentColor)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("传输") {
                row("已接收", AppFormat.bytes(session.receivedBytesEstimate))
                row("文件大小", session.originalSize.map { AppFormat.bytes(Int($0)) } ?? "接收中…")
                row("完整性校验", session.phase == .done ? "SHA-256 通过" : "待还原后校验")
                if session.compressed { row("传输压缩", "已启用") }
            }

            if session.phase == .processing, session.isFinalizing {
                Section {
                    Button(role: .destructive) {
                        receiver.cancelFinalize(session)
                    } label: {
                        Label("停止还原", systemImage: "stop.circle")
                    }
                } footer: {
                    Text("大文件的还原是一次性的密集计算，停止后可以稍后重新开始，已收到的数据不会丢失。")
                }
            }

            Section {
                DisclosureGroup("技术细节", isExpanded: $showTechnical) {
                    row("会话 ID", SessionId.hex(session.sessionId))
                    row("编码方案", session.codec.displayName)
                    row("源块 K / 块长 T", "\(session.K) / \(session.T)")
                    row("每帧块数 m", "\(session.blocksPerFrame)")
                    row("冗余系数 ε", String(format: "%.2f%%", session.epsilon * 100))
                    row("编码块", "\(session.stats.blocksUnique) / \(session.estimatedNeededBlocks)")
                    row("已解源块", "\(session.solvedCount) / \(session.K)")
                    row("帧 通过 / 拒绝", "\(session.stats.framesAccepted) / \(session.stats.framesRejected)")
                    row("块 收到 / 重复", "\(session.stats.blocksReceived) / \(session.stats.blocksDuplicate)")
                    row("最大块序号", "\(session.stats.maxBlockId)")
                    row("单帧成功率",
                        String(format: "%.1f%%",
                               session.stats.estimatedFrameSuccessRate(blocksPerFrame: session.blocksPerFrame) * 100))
                }
                .font(.subheadline)
            } footer: {
                Text("单帧成功率偏低说明识别条件不佳：可尝试稳定手机、拉近距离、调高发送端屏幕亮度，或在设置里换用更高的扫描模式。")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }
}
