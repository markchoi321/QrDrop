//
//  PhotoImportView.swift
//  QrBinary
//
//  Created by Victor on 2026/2/21.
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
            VStack(spacing: 20) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
                
                Text("从相册选择二维码图片")
                    .font(.title2)
                
                Text("支持批量选择多张图片")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                PhotosPicker(selection: $selectedItems,
                             maxSelectionCount: 999,
                             matching: .images) {
                    Label("选择图片", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                             .buttonStyle(.borderedProminent)
                             .padding(.horizontal, 40)
                
                if isProcessing {
                    VStack(spacing: 8) {
                        ProgressView(value: Double(processedCount), total: Double(totalToProcess))
                            .padding(.horizontal, 40)
                        Text("处理中 \(processedCount)/\(totalToProcess)，成功 \(successCount) 张")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if !isProcessing && processedCount > 0 {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                        Text("处理完成：成功 \(successCount)/\(processedCount)")
                            .font(.subheadline)
                    }
                }
                
                Spacer()
            }
            .padding(.top, 40)
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
                    
                    let success = await MainActor.run {
                        receiver.processImage(cgImage)
                    }
                    
                    await MainActor.run {
                        processedCount += 1
                        if success {
                            successCount += 1
                        }
                    }
                } else {
                    await MainActor.run {
                        processedCount += 1
                    }
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
