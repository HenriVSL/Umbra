import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import AVFoundation
#endif

/// Adds anything from an `umbra://` code: contacts, rooms and servers. Camera on iOS, paste or image file elsewhere.
struct ScanSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var result: String?
    @State private var failed = false
    @State private var importingImage = false

    var body: some View {
        NavigationStack {
            Form {
                #if os(iOS)
                Section {
                    QRScannerView { code in apply(code, scanned: true) }
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Point the camera at a contact, room or server code.")
                }
                #endif
                Section("Or paste a link") {
                    TextField("umbra://…", text: $pasted, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                    HStack {
                        Button("Paste") { pasted = Clipboard.string ?? "" }
                        Spacer()
                        Button("Add") { apply(pasted) }.disabled(pasted.isEmpty)
                    }
                    #if !os(iOS)
                    Button("Read QR from image…") { importingImage = true }
                    #endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add by code")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { picked in
                guard case .success(let url) = picked else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let code = QRCodeView.decode(imageAt: url) { apply(code) } else { failed = true }
            }
            .alert(result ?? "", isPresented: .init(get: { result != nil }, set: { if !$0 { result = nil; dismiss() } })) {}
            .alert("Not a valid Umbra code", isPresented: $failed) {}
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private func apply(_ code: String, scanned: Bool = false) {
        guard result == nil else { return }
        do { result = try model.importInvite(code, scannedInPerson: scanned) } catch { failed = true }
    }
}

#if os(iOS)
struct QRScannerView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.start(in: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        private let session = AVCaptureSession()
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func start(in view: PreviewView) {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
            else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            let session = session
            Task.detached { session.startRunning() }
        }

        func stop() {
            let session = session
            Task.detached { session.stopRunning() }
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection
        ) {
            guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  code.hasPrefix("umbra://")
            else { return }
            MainActor.assumeIsolated {
                guard !delivered else { return }
                delivered = true
                onCode(code)
            }
        }
    }
}
#endif
