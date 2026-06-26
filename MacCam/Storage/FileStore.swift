import Foundation
import AppKit

/// Owns the clip destination folder: default `~/Movies/MacCam/`, optional
/// user-selected folder persisted as a security-scoped bookmark, clip URL
/// generation, and retention cleanup. No network access.
final class FileStore {
    private let defaults: UserDefaults
    private let bookmarkKey = "folderBookmark"
    private var resolvedFolder: URL?
    private var isAccessingScoped = false
    private let defaultOverride: URL?
    // Guards the folder-resolution state; `currentFolder()` is called from both
    // the capture queue (nextClipURL) and a background ioQueue (enforce/usage).
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, defaultOverride: URL? = nil) {
        self.defaults = defaults
        self.defaultOverride = defaultOverride
    }

    // MARK: Folder resolution

    func defaultFolder() -> URL {
        if let defaultOverride {
            try? FileManager.default.createDirectory(at: defaultOverride, withIntermediateDirectories: true)
            return defaultOverride
        }
        let movies = (try? FileManager.default.url(
            for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let folder = movies.appendingPathComponent("MacCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Resolves the active folder once (user-selected bookmark if present and
    /// valid, otherwise the default). Subsequent calls return the cached value.
    /// Thread-safe.
    func currentFolder() -> URL {
        lock.lock(); defer { lock.unlock() }
        return resolveFolderLocked()
    }

    private func resolveFolderLocked() -> URL {
        if let resolvedFolder { return resolvedFolder }

        if let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               !stale {
                isAccessingScoped = url.startAccessingSecurityScopedResource()
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                resolvedFolder = url
                return url
            }
            // Stale or unreadable bookmark → drop it and fall back.
            defaults.removeObject(forKey: bookmarkKey)
        }

        let fallback = defaultFolder()
        resolvedFolder = fallback
        return fallback
    }

    func setFolder(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        stopAccessingLocked()
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: bookmarkKey)
        }
        resolvedFolder = nil
        _ = resolveFolderLocked()  // re-resolve and begin scoped access
    }

    func stopAccessing() {
        lock.lock(); defer { lock.unlock() }
        stopAccessingLocked()
    }

    private func stopAccessingLocked() {
        if isAccessingScoped, let url = resolvedFolder {
            url.stopAccessingSecurityScopedResource()
        }
        isAccessingScoped = false
    }

    // MARK: Clip URLs and cleanup

    func nextClipURL(now: Date) -> URL {
        let name = ClipNaming.filename(for: now, calendar: Calendar.current)
        return currentFolder().appendingPathComponent(name)
    }

    func runCleanup(olderThanDays days: Int, now: Date = Date()) {
        let folder = currentFolder()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let movs = items.filter { $0.pathExtension.lowercased() == "mov" }
        let withDates: [(url: URL, modified: Date)] = movs.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return date.map { (url, $0) }
        }
        for url in ClipNaming.expired(files: withDates, olderThanDays: days, now: now) {
            try? fm.removeItem(at: url)
        }
    }

    func openInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentFolder()])
    }

    // MARK: Disk usage / limits

    func clipFiles() -> [ClipFile] {
        let folder = currentFolder()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "mov" }.compactMap { url in
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let date = v?.contentModificationDate, let size = v?.fileSize else { return nil }
            return ClipFile(url: url, size: Int64(size), modified: date)
        }
    }

    func folderUsage() -> (count: Int, totalBytes: Int64) {
        let files = clipFiles()
        return (files.count, files.reduce(0) { $0 + $1.size })
    }

    func volumeFreeBytes() -> Int64 {
        let url = currentFolder()
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Delete oldest clips to satisfy the limits; returns whether usage is within
    /// limits afterward.
    @discardableResult
    func enforce(maxBytes: Int64, minFreeBytes: Int64, protecting: Set<URL>) -> Bool {
        let files = clipFiles()
        let total = files.reduce(0) { $0 + $1.size }
        let free = volumeFreeBytes()
        let toDelete = StorageMath.clipsToDelete(
            files: files, totalBytes: total, freeBytes: free,
            maxBytes: maxBytes, minFreeBytes: minFreeBytes, protecting: protecting)
        var freed: Int64 = 0
        let sizeByURL = Dictionary(uniqueKeysWithValues: files.map { ($0.url, $0.size) })
        for url in toDelete where (try? FileManager.default.removeItem(at: url)) != nil {
            freed += sizeByURL[url] ?? 0
        }
        return !StorageMath.overLimit(totalBytes: total - freed, freeBytes: free + freed,
                                      maxBytes: maxBytes, minFreeBytes: minFreeBytes)
    }
}
