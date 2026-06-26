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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Folder resolution

    func defaultFolder() -> URL {
        let movies = (try? FileManager.default.url(
            for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let folder = movies.appendingPathComponent("MacCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Resolves the active folder once (user-selected bookmark if present and
    /// valid, otherwise the default). Subsequent calls return the cached value.
    func currentFolder() -> URL {
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
        stopAccessing()
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: bookmarkKey)
        }
        resolvedFolder = nil
        _ = currentFolder()  // re-resolve and begin scoped access
    }

    func stopAccessing() {
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
}
