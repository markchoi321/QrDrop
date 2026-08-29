//
//  PhotoImportView.swift
//  QrDrop
//
//  从相册批量导入二维码截图。适用于对方把二维码序列截图发过来的场景。
//

import SwiftUI
import PhotosUI

struct PhotoImportView: View {
    @ObservedObject var receiver: FileReceiver
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isProcessing = false
    @State private var processedCount = 0
    @State private var successCount = 0
    @State private var totalToProcess = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text("从相册导入二维码")
                        .font(.title3.bold())
                    Text("可以一次选中多张截图，识别顺序不影响结果。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 36)

                if isProcessing {
                    VStack(spacing: 10) {
                        ProgressView(value: Double(processedCount), total: Double(max(1, totalToProcess)))
                        Text("正在识别 \(processedCount)/\(totalToProcess) · 有效 \(successCount) 张")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .card()
                    .padding(.horizontal)
                } else if processedCount > 0 {
                    VStack(spacing: 8) {
                        Image(systemName: successCount > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(successCount > 0 ? Theme.success : Theme.warning)
                        Text(successCount > 0
                             ? "已从 \(successCount)/\(processedCount) 张图片中读出数据"
                             : "这些图片里没有可用的二维码")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .card()
                    .padding(.horizontal)
                }

                Spacer()

                PhotosPicker(selection: $selectedItems,
                             maxSelectionCount: 999,
                             matching: .images) {
                    Label("选择图片", systemImage: "photo.badge.plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isProcessing)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("导入图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: selectedItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                processSelectedPhotos(newItems)
            }
        }
    }

    private func processSelectedPhotos(_ items: [PhotosPickerItem]) {
        isProcessing = true
        processedCount = 0
        successCount = 0
        totalToProcess = items.count

        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data),
                   let cgImage = uiImage.cgImage {

                    // 识别与解码都在后台，这里只等结果
                    let success = await receiver.processImage(cgImage)

                    await MainActor.run {
                        processedCount += 1
                        if success { successCount += 1 }
                    }
                } else {
                    await MainActor.run { processedCount += 1 }
                }
            }

            await MainActor.run {
                isProcessing = false
                receiver.addLog("图片批量导入完成：成功 \(successCount)/\(totalToProcess)")
                selectedItems.removeAll()
            }
        }
    }
}
