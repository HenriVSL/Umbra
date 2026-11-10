import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Renders a string as a QR code, with crisp (unsmoothed) modules.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(.white, in: .rect(cornerRadius: 12))
                .accessibilityLabel("QR code")
        } else {
            Text("Could not render code").foregroundStyle(.secondary)
        }
    }

    static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// Finds a QR code in an image file (used on platforms without a camera scanner).
    static func decode(imageAt url: URL) -> String? {
        guard let image = CIImage(contentsOf: url),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static var string: String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

/// A QR code with its link, a secrecy warning when relevant, and copy/share actions.
struct InviteCard: View {
    let title: String
    let link: String
    var warning: String?

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            QRCodeView(text: link).frame(maxWidth: 280)
            if let warning {
                Label(warning, systemImage: "exclamationmark.shield")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button("Copy link", systemImage: "doc.on.doc") { Clipboard.copy(link) }
                ShareLink(item: link)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }
}
