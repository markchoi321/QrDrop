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

struct CameraScannerView: View {
    @ObservedObject var receiver: FileReceiver
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = CameraScanner()

    @State private var lastReceivedInfo: String = ""
    @State private var scanCount = 0

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreviewView(session: scanner.session)
                    .ignoresSafeArea()

                VStack {
                    HStack {
                        Label("引擎: \(receiver.selectedEngine.rawValue)",
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

                    VStack(spacing: 8) {
                        if !lastReceivedInfo.isEmpty {
                            Text(lastReceivedInfo)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.green)
                                .padding(.horizontal)
                        }

                        Text("已扫描 \(scanCount) 个片段")
                            .font(.headline)
                            .foregroundStyle(.white)

                        ForEach(Array(receiver.fileInfo.keys.sorted()), id: \.self) { fileId in
                            if let info = receiver.fileInfo[fileId] {
                                let received = receiver.files[fileId]?.count ?? 0
                                let total = info.totalChunks
                                HStack {
                                    Text(info.fileName)
                                        .font(.caption)
                                    Spacer()
                                    Text("\(received)/\(total)")
                                        .font(.caption.bold())
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal)

                                ProgressView(value: Double(received), total: Double(total))
                                    .tint(.green)
                                    .padding(.horizontal)
                            }
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
                }
            }
            .navigationTitle("扫描二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        scanner.stop()
                        dismiss()
                    }
                }
            }
            .onAppear {
                scanner.engine = receiver.selectedEngine
                scanner.onQRCodeDetected = { [weak receiver] strings in
                    guard let receiver = receiver else { return }
                    Task { @MainActor in
                        for str in strings {
                            if receiver.processQRCode(str) {
                                scanCount += 1
                                if let data = str.data(using: .utf8),
                                   let chunk = try? JSONDecoder().decode(QRChunk.self, from: data) {
                                    lastReceivedInfo = "✓ \(chunk.fileName) 片段 \(chunk.chunkIndex + 1)/\(chunk.totalChunks)"
                                }
                            }
                        }
                    }
                }
                scanner.start()
            }
            .onDisappear {
                scanner.stop()
            }
        }
    }
}

// MARK: - Camera Scanner (AVFoundation + Vision)

class CameraScanner: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onQRCodeDetected: (([String]) -> Void)?
    var engine: QREngine = .avFoundation

    private let metadataOutput = AVCaptureMetadataOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let visionQueue = DispatchQueue(label: "vision.processing.queue", qos: .userInitiated)
    private var isRunning = false
    private var isProcessingVisionFrame = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

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
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

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

    // MARK: - AVCaptureMetadataOutputObjectsDelegate (AVFoundation)

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        let strings = metadataObjects.compactMap { obj -> String? in
            guard let readableObj = obj as? AVMetadataMachineReadableCodeObject,
                  readableObj.type == .qr else { return nil }
            return readableObj.stringValue
        }

        if !strings.isEmpty {
            onQRCodeDetected?(strings)
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Vision)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !isProcessingVisionFrame else { return }
        isProcessingVisionFrame = true

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            isProcessingVisionFrame = false
            return
        }

        let request = VNDetectBarcodesRequest { [weak self] request, error in
            defer { self?.isProcessingVisionFrame = false }

            guard let results = request.results as? [VNBarcodeObservation] else { return }

            let strings = results.compactMap { observation -> String? in
                guard observation.symbology == .qr else { return nil }
                return observation.payloadStringValue
            }

            if !strings.isEmpty {
                self?.onQRCodeDetected?(strings)
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
