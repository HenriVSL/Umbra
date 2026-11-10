import Foundation

/// Minimal baseline JPEG encoder for 8-bit grayscale images (standard Huffman tables, quality 100).
/// With block-aligned content, such as a QR code drawn with modules a multiple of 8 px, every 8×8
/// block is a single colour and the output decodes to exactly the input.
public enum JPEG {
    public static func encodeGrayscale(width: Int, height: Int, pixels: [UInt8]) -> Data {
        precondition(width > 0 && height > 0 && width <= 65_535 && height <= 65_535 && pixels.count == width * height)
        var out = Data([0xFF, 0xD8])
        // JFIF header, 1:1 aspect.
        out.append(contentsOf: [0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        // Quantization table 0: all ones (no quality loss beyond rounding).
        out.append(contentsOf: [0xFF, 0xDB, 0x00, 0x43, 0x00])
        out.append(contentsOf: [UInt8](repeating: 1, count: 64))
        // Frame: baseline, 8-bit, one component.
        out.append(contentsOf: [0xFF, 0xC0, 0x00, 0x0B, 0x08, UInt8(height >> 8), UInt8(height & 0xFF),
                                UInt8(width >> 8), UInt8(width & 0xFF), 0x01, 0x01, 0x11, 0x00])
        appendHuffmanTable(&out, id: 0x00, counts: dcCounts, symbols: dcSymbols)
        appendHuffmanTable(&out, id: 0x10, counts: acCounts, symbols: acSymbols)
        out.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])

        var writer = BitWriter()
        var previousDC = 0
        var block = [Double](repeating: 0, count: 64)
        for by in stride(from: 0, to: height, by: 8) {
            for bx in stride(from: 0, to: width, by: 8) {
                for y in 0..<8 {
                    for x in 0..<8 {
                        // Edge blocks repeat the last row/column.
                        let px = pixels[min(by + y, height - 1) * width + min(bx + x, width - 1)]
                        block[y * 8 + x] = Double(px) - 128
                    }
                }
                let coefficients = dct(block)
                let dc = coefficients[0]
                writer.writeDC(dc - previousDC)
                previousDC = dc
                var run = 0
                for k in 1..<64 {
                    let value = coefficients[zigzag[k]]
                    if value == 0 {
                        run += 1
                        continue
                    }
                    while run > 15 {
                        writer.write(acCodes[0xF0])
                        run -= 16
                    }
                    writer.writeAC(run: run, value: value)
                    run = 0
                }
                if run > 0 { writer.write(acCodes[0x00]) }
            }
        }
        writer.flush()
        out.append(writer.bytes)
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    /// 2-D DCT-II, quantized by 1 (rounded). Returns coefficients in natural order.
    private static func dct(_ input: [Double]) -> [Int] {
        var rows = [Double](repeating: 0, count: 64)
        for y in 0..<8 {
            for u in 0..<8 {
                var sum = 0.0
                for x in 0..<8 { sum += input[y * 8 + x] * cosines[x * 8 + u] }
                rows[y * 8 + u] = sum * (u == 0 ? 0.5.squareRoot() : 1) / 2
            }
        }
        var out = [Int](repeating: 0, count: 64)
        for u in 0..<8 {
            for v in 0..<8 {
                var sum = 0.0
                for y in 0..<8 { sum += rows[y * 8 + u] * cosines[y * 8 + v] }
                out[v * 8 + u] = Int((sum * (v == 0 ? 0.5.squareRoot() : 1) / 2).rounded())
            }
        }
        return out
    }

    /// cos((2x + 1)uπ/16) at index x * 8 + u.
    private static let cosines: [Double] = (0..<64).map { i in
        let x = Double(i / 8), u = Double(i % 8)
        let angle: Double = (2 * x + 1) * u * Double.pi / 16
        return cos(angle)
    }

    private static let zigzag = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    // Standard luminance tables (ITU T.81 Annex K.3).
    static let dcCounts: [UInt8] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
    static let dcSymbols: [UInt8] = Array(0...11)
    static let acCounts: [UInt8] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D]
    static let acSymbols: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA,
    ]

    typealias Code = (bits: Int, length: Int)

    private static func codes(_ counts: [UInt8], _ symbols: [UInt8]) -> [Code] {
        var table = [Code](repeating: (0, 0), count: 256)
        var code = 0
        var k = 0
        for length in 1...16 {
            for _ in 0..<Int(counts[length - 1]) {
                table[Int(symbols[k])] = (code, length)
                code += 1
                k += 1
            }
            code <<= 1
        }
        return table
    }

    private static let dcCodes = codes(dcCounts, dcSymbols)
    private static let acCodes = codes(acCounts, acSymbols)

    private static func appendHuffmanTable(_ out: inout Data, id: UInt8, counts: [UInt8], symbols: [UInt8]) {
        let length = 2 + 1 + 16 + symbols.count
        out.append(contentsOf: [0xFF, 0xC4, UInt8(length >> 8), UInt8(length & 0xFF), id])
        out.append(contentsOf: counts)
        out.append(contentsOf: symbols)
    }

    private struct BitWriter {
        var bytes = Data()
        private var buffer = 0
        private var count = 0

        mutating func write(_ code: Code) { write(code.bits, code.length) }

        mutating func write(_ bits: Int, _ length: Int) {
            for i in stride(from: length - 1, through: 0, by: -1) {
                buffer = buffer << 1 | (bits >> i) & 1
                count += 1
                if count == 8 { emit() }
            }
        }

        /// Magnitude category, then the value's bits (negative values as one's complement).
        mutating func writeDC(_ value: Int) {
            let category = Self.category(value)
            write(JPEG.dcCodes[category])
            if category > 0 { write(value < 0 ? value + (1 << category) - 1 : value, category) }
        }

        mutating func writeAC(run: Int, value: Int) {
            let category = Self.category(value)
            write(JPEG.acCodes[run << 4 | category])
            write(value < 0 ? value + (1 << category) - 1 : value, category)
        }

        /// Pads the last byte with ones, as the standard requires.
        mutating func flush() {
            while count != 0 { write(1, 1) }
        }

        private mutating func emit() {
            bytes.append(UInt8(buffer))
            if buffer == 0xFF { bytes.append(0x00) }  // byte stuffing
            buffer = 0
            count = 0
        }

        private static func category(_ value: Int) -> Int {
            var magnitude = abs(value)
            var bits = 0
            while magnitude > 0 {
                bits += 1
                magnitude >>= 1
            }
            return bits
        }
    }
}
