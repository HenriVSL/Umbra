#if canImport(CoreImage) && canImport(ImageIO)
import CoreImage
import Foundation
import ImageIO
import Testing
import UmbraQR

/// Checks the generator against Apple's independent QR detector and JPEG decoder.
@Suite struct QRTests {
    func decodeImage(_ jpeg: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func grayPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    func scan(_ jpeg: Data) throws -> String? {
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil))
        let features = detector.features(in: CIImage(cgImage: try decodeImage(jpeg)))
        return (features.first as? CIQRCodeFeature)?.messageString
    }

    @Test(arguments: [
        "x",
        "umbra://contact?n=Alpha&s=SIdHTO-fQaoiWPXv3bZCzIiZmP25j8FAZPe47YeRuGw&x=PttgfieQOJQ5zHMFISwW1ngxRwM7nBNCnZxKH9sGT30",
        "umbra://server?n=Field%20relay&h=203.0.113.10&p=7443&k=r5FF6TQz0d1kq98qnco7vDSDt2464RKVfW0q5XwLeUs&a=skfVEYRai-ZBVpBFMD-qpgrSiasYqT0di-xLZniY1jc",
        String(repeating: "0123456789abcdef", count: 25),
        String(repeating: "Umbra ", count: 150),
    ])
    func scansBack(text: String) throws {
        for ecl in QRCode.ErrorCorrection.allCases {
            let qr = try QRCode(text: text, minimumCorrection: ecl)
            #expect(try scan(qr.jpeg(moduleSize: 8)) == text, "version \(qr.version) ecl \(qr.errorCorrection)")
        }
    }

    @Test func coversManyVersions() throws {
        let versions = Set(try [1, 40, 120, 300, 600, 900].map { try QRCode(text: String(repeating: "a", count: $0)).version })
        #expect(versions.count == 6 && versions.contains { $0 >= 7 } && versions.contains { $0 >= 10 })
        #expect(throws: QRCode.EncodingError.tooLong) { try QRCode(text: String(repeating: "a", count: 3000), minimumCorrection: .high) }
    }

    @Test func blockAlignedImageIsExact() throws {
        let side = 64
        let pixels = (0..<(side * side)).map { i in ((i % side) / 8 + (i / side) / 8) % 2 == 0 ? UInt8(0) : 255 }
        let image = try decodeImage(JPEG.encodeGrayscale(width: side, height: side, pixels: pixels))
        #expect(try grayPixels(image) == pixels)
    }

    @Test func arbitraryImageIsClose() throws {
        var rng = SystemRandomNumberGenerator()
        let (width, height) = (37, 21)  // not multiples of 8: exercises edge blocks
        let pixels = (0..<(width * height)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let decoded = try grayPixels(try decodeImage(JPEG.encodeGrayscale(width: width, height: height, pixels: pixels)))
        let worst = zip(pixels, decoded).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 4)
    }
}
#endif
