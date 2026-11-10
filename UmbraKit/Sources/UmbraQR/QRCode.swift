/// QR code generator (ISO/IEC 18004, byte mode), dependency-free so the static Linux server can draw
/// its own invite. Follows the structure of Project Nayuki's reference implementation.
public struct QRCode: Sendable {
    public enum ErrorCorrection: Int, Sendable, CaseIterable {
        case low, medium, quartile, high

        /// The two format bits that encode this level.
        var formatBits: Int { [1, 0, 3, 2][rawValue] }
    }

    public enum EncodingError: Error { case tooLong }

    public let version: Int
    public let size: Int
    public let errorCorrection: ErrorCorrection
    public private(set) var mask: Int
    private var modules: [Bool]
    private var isFunction: [Bool]

    /// Picks the smallest version that fits, then the strongest error correction that still fits it.
    public init(text: String, minimumCorrection: ErrorCorrection = .medium) throws {
        let data = Array(text.utf8)
        var version = 0
        var usedBits = 0
        for v in 1...40 {
            usedBits = 4 + Self.countBits(v) + data.count * 8
            if data.count < 1 << Self.countBits(v), usedBits <= Self.dataCodewords(v, minimumCorrection) * 8 {
                version = v
                break
            }
        }
        guard version > 0 else { throw EncodingError.tooLong }
        var ecl = minimumCorrection
        for better in ErrorCorrection.allCases where better.rawValue > ecl.rawValue {
            if usedBits <= Self.dataCodewords(version, better) * 8 { ecl = better }
        }

        // Segment, terminator, byte padding, pad codewords.
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for i in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
        }
        append(0b0100, 4)
        append(data.count, Self.countBits(version))
        for byte in data { append(Int(byte), 8) }
        let capacity = Self.dataCodewords(version, ecl) * 8
        append(0, min(4, capacity - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var pad = 0xEC
        while bits.count < capacity {
            append(pad, 8)
            pad ^= 0xEC ^ 0x11
        }
        var codewords = [UInt8](repeating: 0, count: bits.count / 8)
        for (i, bit) in bits.enumerated() where bit { codewords[i >> 3] |= 0x80 >> UInt8(i & 7) }

        self.version = version
        size = version * 4 + 17
        errorCorrection = ecl
        modules = Array(repeating: false, count: size * size)
        isFunction = Array(repeating: false, count: size * size)
        mask = 0

        drawFunctionPatterns()
        drawCodewords(addErrorCorrection(codewords))
        var best = 0
        var bestPenalty = Int.max
        for candidate in 0..<8 {
            applyMask(candidate)
            drawFormatBits(candidate)
            let penalty = penaltyScore()
            if penalty < bestPenalty {
                best = candidate
                bestPenalty = penalty
            }
            applyMask(candidate)  // XOR again to undo
        }
        mask = best
        applyMask(best)
        drawFormatBits(best)
    }

    /// True for a dark module. Coordinates outside the symbol are light (the quiet zone).
    public subscript(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < size && y < size && modules[y * size + x]
    }

    // MARK: Function patterns

    private mutating func set(_ x: Int, _ y: Int, _ dark: Bool, function: Bool = true) {
        modules[y * size + x] = dark
        if function { isFunction[y * size + x] = true }
    }

    private mutating func drawFunctionPatterns() {
        for i in 0..<size {
            set(6, i, i % 2 == 0)
            set(i, 6, i % 2 == 0)
        }
        for (x, y) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4...4 {
                for dx in -4...4 where (0..<size).contains(x + dx) && (0..<size).contains(y + dy) {
                    let distance = max(abs(dx), abs(dy))
                    set(x + dx, y + dy, distance != 2 && distance != 4)
                }
            }
        }
        let positions = alignmentPositions()
        let n = positions.count
        for i in 0..<n {
            for j in 0..<n where !(i == 0 && j == 0) && !(i == 0 && j == n - 1) && !(i == n - 1 && j == 0) {
                for dy in -2...2 {
                    for dx in -2...2 { set(positions[i] + dx, positions[j] + dy, max(abs(dx), abs(dy)) != 1) }
                }
            }
        }
        drawFormatBits(0)  // reserves the area; redrawn once the mask is chosen
        drawVersion()
    }

    private func alignmentPositions() -> [Int] {
        guard version > 1 else { return [] }
        let count = version / 7 + 2
        let step = version == 32 ? 26 : (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2
        var result = [6]
        for i in 0..<(count - 1) { result.insert(size - 7 - i * step, at: 1) }
        return result
    }

    private mutating func drawFormatBits(_ mask: Int) {
        let data = errorCorrection.formatBits << 3 | mask
        var rem = data
        for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
        let bits = (data << 10 | rem) ^ 0x5412
        func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }

        for i in 0...5 { set(8, i, bit(i)) }
        set(8, 7, bit(6))
        set(8, 8, bit(7))
        set(7, 8, bit(8))
        for i in 9..<15 { set(14 - i, 8, bit(i)) }

        for i in 0..<8 { set(size - 1 - i, 8, bit(i)) }
        for i in 8..<15 { set(8, size - 15 + i, bit(i)) }
        set(8, size - 8, true)  // always dark
    }

    private mutating func drawVersion() {
        guard version >= 7 else { return }
        var rem = version
        for _ in 0..<12 { rem = (rem << 1) ^ ((rem >> 11) * 0x1F25) }
        let bits = version << 12 | rem
        for i in 0..<18 {
            let dark = (bits >> i) & 1 == 1
            let a = size - 11 + i % 3, b = i / 3
            set(a, b, dark)
            set(b, a, dark)
        }
    }

    // MARK: Data

    /// Splits into blocks, appends Reed–Solomon codewords to each, and interleaves.
    private func addErrorCorrection(_ data: [UInt8]) -> [UInt8] {
        let blockCount = Self.blocks[errorCorrection.rawValue][version]
        let eccLength = Self.eccPerBlock[errorCorrection.rawValue][version]
        let raw = Self.rawDataModules(version) / 8
        let shortBlocks = blockCount - raw % blockCount
        let shortLength = raw / blockCount
        let divisor = Self.reedSolomonDivisor(eccLength)

        var blocks: [[UInt8]] = []
        var k = 0
        for i in 0..<blockCount {
            var block = Array(data[k..<(k + shortLength - eccLength + (i < shortBlocks ? 0 : 1))])
            k += block.count
            let ecc = Self.reedSolomonRemainder(block, divisor)
            if i < shortBlocks { block.append(0) }
            blocks.append(block + ecc)
        }
        var result: [UInt8] = []
        for i in 0..<blocks[0].count {
            for (j, block) in blocks.enumerated() where i != shortLength - eccLength || j >= shortBlocks {
                result.append(block[i])
            }
        }
        return result
    }

    /// Zigzag placement in two-column strips, right to left, skipping function modules.
    private mutating func drawCodewords(_ data: [UInt8]) {
        var i = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vertical in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = (right + 1) & 2 == 0
                    let y = upward ? size - 1 - vertical : vertical
                    if !isFunction[y * size + x], i < data.count * 8 {
                        modules[y * size + x] = (data[i >> 3] >> UInt8(7 - (i & 7))) & 1 == 1
                        i += 1
                    }
                }
            }
            right -= 2
        }
    }

    private mutating func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size where !isFunction[y * size + x] {
                let invert = switch mask {
                case 0: (x + y) % 2 == 0
                case 1: y % 2 == 0
                case 2: x % 3 == 0
                case 3: (x + y) % 3 == 0
                case 4: (x / 3 + y / 2) % 2 == 0
                case 5: x * y % 2 + x * y % 3 == 0
                case 6: (x * y % 2 + x * y % 3) % 2 == 0
                default: ((x + y) % 2 + x * y % 3) % 2 == 0
                }
                if invert { modules[y * size + x].toggle() }
            }
        }
    }

    // MARK: Mask penalty (lower reads more reliably)

    private func penaltyScore() -> Int {
        var result = 0
        for horizontal in [true, false] {
            for a in 0..<size {
                var runDark = false
                var run = 0
                var history = [Int](repeating: 0, count: 7)
                for b in 0..<size {
                    let dark = horizontal ? self[b, a] : self[a, b]
                    if dark == runDark {
                        run += 1
                        if run == 5 { result += 3 } else if run > 5 { result += 1 }
                    } else {
                        addHistory(run, &history)
                        if !runDark { result += finderLike(history) * 40 }
                        runDark = dark
                        run = 1
                    }
                }
                if runDark {
                    addHistory(run, &history)
                    run = 0
                }
                addHistory(run + size, &history)
                result += finderLike(history) * 40
            }
        }
        for y in 0..<(size - 1) {
            for x in 0..<(size - 1) {
                let c = self[x, y]
                if c == self[x + 1, y], c == self[x, y + 1], c == self[x + 1, y + 1] { result += 3 }
            }
        }
        let dark = modules.filter { $0 }.count
        let total = size * size
        result += ((abs(dark * 20 - total * 10) + total - 1) / total - 1) * 10
        return result
    }

    private func addHistory(_ run: Int, _ history: inout [Int]) {
        history.removeLast()
        history.insert(history[0] == 0 ? run + size : run, at: 0)
    }

    private func finderLike(_ h: [Int]) -> Int {
        let n = h[1]
        let core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n
        return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0)
    }

    // MARK: Tables and arithmetic

    private static func countBits(_ version: Int) -> Int { version < 10 ? 8 : 16 }

    private static func rawDataModules(_ version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let align = version / 7 + 2
            result -= (25 * align - 10) * align - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    private static func dataCodewords(_ version: Int, _ ecl: ErrorCorrection) -> Int {
        rawDataModules(version) / 8 - eccPerBlock[ecl.rawValue][version] * blocks[ecl.rawValue][version]
    }

    private static func reedSolomonDivisor(_ degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    private static func reedSolomonRemainder(_ data: [UInt8], _ divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for i in result.indices { result[i] ^= multiply(divisor[i], factor) }
        }
        return result
    }

    /// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
    private static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= Int((y >> UInt8(i)) & 1) * Int(x)
        }
        return UInt8(z)
    }

    // Indexed [error correction][version]; index 0 is unused.
    private static let eccPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]
    private static let blocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]
}
