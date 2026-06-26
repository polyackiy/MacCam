import Foundation

struct ClipFile: Equatable {
    let url: URL
    let size: Int64
    let modified: Date
}

/// Pure storage-retention math: decide which clips to delete to bring usage back
/// within a size cap and/or free-space floor, oldest first, never touching a
/// protected (in-flight) clip.
enum StorageMath {
    static let bytesPerGB: Double = 1_000_000_000

    /// Decimal gigabytes (1e9) → bytes. `0` stays `0` (meaning "no limit").
    static func gbToBytes(_ gb: Double) -> Int64 { Int64((gb * bytesPerGB).rounded()) }

    /// Bytes → decimal gigabytes, for display.
    static func bytesToGB(_ bytes: Int64) -> Double { Double(bytes) / bytesPerGB }

    /// True if current usage violates an enabled limit (`0` disables a limit).
    static func overLimit(totalBytes: Int64, freeBytes: Int64,
                          maxBytes: Int64, minFreeBytes: Int64) -> Bool {
        (maxBytes > 0 && totalBytes > maxBytes) || (minFreeBytes > 0 && freeBytes < minFreeBytes)
    }

    /// Oldest-first selection so that, after deleting the returned URLs, total
    /// size ≤ `maxBytes` (if > 0) and free ≥ `minFreeBytes` (if > 0). Best effort:
    /// stops when constraints are met or candidates are exhausted.
    static func clipsToDelete(
        files: [ClipFile], totalBytes: Int64, freeBytes: Int64,
        maxBytes: Int64, minFreeBytes: Int64, protecting: Set<URL>
    ) -> [URL] {
        guard maxBytes > 0 || minFreeBytes > 0 else { return [] }
        var total = totalBytes
        var free = freeBytes
        var result: [URL] = []
        let candidates = files
            .filter { !protecting.contains($0.url) }
            .sorted { $0.modified < $1.modified }
        for clip in candidates {
            if !overLimit(totalBytes: total, freeBytes: free,
                          maxBytes: maxBytes, minFreeBytes: minFreeBytes) {
                break
            }
            result.append(clip.url)
            total -= clip.size
            free += clip.size
        }
        return result
    }
}
