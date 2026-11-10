import Foundation

extension QRCode {
    /// Two module rows per text line using half blocks, forced black on white with ANSI colours so it
    /// scans on dark terminals too.
    public func terminalString(quietZone: Int = 2) -> String {
        let range = -quietZone..<(size + quietZone)
        var lines: [String] = []
        for y in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
            var line = "\u{1B}[30;47m"
            for x in range {
                switch (self[x, y], self[x, y + 1]) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines.joined(separator: "\n")
    }

    /// Black-on-white JPEG. `moduleSize` is rounded up to a multiple of 8 so every JPEG block is one
    /// solid colour and the image stays exact despite the lossy format.
    public func jpeg(moduleSize: Int = 16, quietZone: Int = 4) -> Data {
        let scale = max(8, (moduleSize + 7) / 8 * 8)
        let side = (size + 2 * quietZone) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0..<side {
            let my = y / scale - quietZone
            for x in 0..<side where self[x / scale - quietZone, my] {
                pixels[y * side + x] = 0
            }
        }
        return JPEG.encodeGrayscale(width: side, height: side, pixels: pixels)
    }
}
