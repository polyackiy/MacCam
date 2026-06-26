import Foundation

/// A coarse 16×9 ignore mask painted over the frame. Ignored cells are excluded
/// from motion analysis (neither counted as changed nor in the active total), so
/// the sensitivity threshold stays "fraction of the active area".
struct MotionMask: Equatable {
    static let cols = 16
    static let rows = 9
    static let count = cols * rows

    private(set) var ignored: [Bool]

    init() { ignored = Array(repeating: false, count: Self.count) }

    /// Parse a `count`-length string of `'0'`/`'1'`. Returns nil on bad length
    /// or unexpected characters.
    init?(encoded: String) {
        guard encoded.count == Self.count else { return nil }
        var arr = [Bool]()
        arr.reserveCapacity(Self.count)
        for ch in encoded {
            switch ch {
            case "0": arr.append(false)
            case "1": arr.append(true)
            default: return nil
            }
        }
        ignored = arr
    }

    var isEmpty: Bool { !ignored.contains(true) }
    var allIgnored: Bool { !ignored.contains(false) }
    var ignoredCount: Int { ignored.lazy.filter { $0 }.count }

    private func index(_ col: Int, _ row: Int) -> Int { row * Self.cols + col }
    func cell(_ col: Int, _ row: Int) -> Bool { ignored[index(col, row)] }
    mutating func toggle(_ col: Int, _ row: Int) { ignored[index(col, row)].toggle() }
    mutating func set(_ col: Int, _ row: Int, _ value: Bool) { ignored[index(col, row)] = value }
    mutating func clear() { ignored = Array(repeating: false, count: Self.count) }
    mutating func invert() { ignored = ignored.map { !$0 } }

    func encoded() -> String { String(ignored.map { $0 ? "1" : "0" }) }

    /// Per-pixel ignore lookup for an analysis buffer of the given size
    /// (`true` = ignore this pixel).
    func pixelLookup(width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let row = min(Self.rows - 1, y * Self.rows / height)
            for x in 0..<width {
                let col = min(Self.cols - 1, x * Self.cols / width)
                out[y * width + x] = ignored[row * Self.cols + col]
            }
        }
        return out
    }
}
