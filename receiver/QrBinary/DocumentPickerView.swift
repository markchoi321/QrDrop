//
//  DocumentPickerView.swift
//  QrBinary
//
//  Created by Victor on 2026/2/21.
//

import SwiftUI
import UniformTypeIdentifiers

struct DocumentPickerView: UIViewControllerRepresentable {
    @ObservedObject var receiver: FileReceiver
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .item])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(receiver: receiver, dismiss: dismiss)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let receiver: FileReceiver
        let dismiss: DismissAction

        init(receiver: FileReceiver, dismiss: DismissAction) {
            self.receiver = receiver
            self.dismiss = dismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                Task { @MainActor in
                    do {
                        try receiver.loadProgress(from: data)
                    } catch {
                        receiver.addLog("加载进度失败: \(error.localizedDescription)", isError: true)
                    }
                }
            } catch {
                Task { @MainActor in
                    receiver.addLog("读取文件失败: \(error.localizedDescription)", isError: true)
                }
            }

            dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            dismiss()
        }
    }
}

