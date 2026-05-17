import Foundation

/// Cache + filesystem watcher for the user-exported bookmarks HTML file.
///
/// Without this, `SafariBookmarks.read()` runs on every `b` / `B` press
/// — fine for small files, but re-parsing a multi-MB Netscape export on
/// every keypress is wasteful and adds perceptible latency to the
/// vomnibar. The store reads once at startup, then refreshes only when
/// the file's parent directory changes (via
/// `DispatchSource.makeFileSystemObjectSource`).
///
/// **Why watch the directory, not the file?** When Safari re-exports
/// bookmarks it atomically replaces the file (write to tmp, rename over
/// the target). The file descriptor we'd opened on the old file becomes
/// stale, and the rename event doesn't fire for the new inode. Watching
/// the parent directory survives the swap.
final class BookmarksStore: @unchecked Sendable {
    static let shared = BookmarksStore()

    private let path: URL
    private let lock = NSLock()
    private var cached: Result<[SafariBookmarks.Entry], SafariBookmarks.ReadError>
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var pendingRefresh: DispatchWorkItem?
    private let refreshQueue: DispatchQueue

    init(path: URL = SafariBookmarks.defaultPath) {
        self.path = path
        self.cached = .failure(.fileMissing)
        self.refreshQueue = DispatchQueue(label: "io.taylorfinklea.vimkeys.bookmarks-store")
    }

    /// Bookmark folder (parent of `bookmarks.html`). Surfaced so the
    /// status menu's "Open Bookmarks Folder" button has a stable URL,
    /// and so callers can offer to reveal it in Finder.
    var folder: URL {
        path.deletingLastPathComponent()
    }

    /// Returns the most-recently-cached read result. Cheap — no disk I/O.
    func current() -> Result<[SafariBookmarks.Entry], SafariBookmarks.ReadError> {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Start watching the parent directory and seed the cache with the
    /// current file contents. Idempotent.
    func start() {
        ensureDirectoryExists()
        refresh()
        attachDirectoryWatcher()
    }

    /// Force a re-read. Wired to the status menu's "Re-import bookmarks"
    /// button so users can verify a fresh export landed without waiting
    /// for the watcher to fire.
    func refresh() {
        let result = SafariBookmarks.read(at: path)
        lock.lock()
        cached = result
        lock.unlock()
    }

    /// Tear the watcher down — used by tests; production code keeps the
    /// singleton alive for the app lifetime.
    func stop() {
        dirSource?.cancel()
        dirSource = nil
    }

    private func ensureDirectoryExists() {
        // Best-effort: we can't read ~/Library/Safari without FDA, but
        // ~/Documents is unprivileged for non-sandboxed apps. If the
        // create fails (e.g. read-only home, weird perms), the watcher
        // path below will silently no-op and the vomnibar will surface
        // a "file missing" message when the user presses `b`.
        let dir = folder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func attachDirectoryWatcher() {
        guard dirSource == nil else { return }
        let dirPath = folder.path
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: refreshQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRefresh()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if dirFD >= 0 {
                close(dirFD)
                dirFD = -1
            }
        }
        source.resume()
        dirSource = source
    }

    /// Debounce — Safari's export-bookmarks flow generates several
    /// directory events back-to-back (temp file write, rename, etc.).
    /// Without coalescing we'd re-parse the file 3-4 times per export.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        pendingRefresh = work
        refreshQueue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }
}
