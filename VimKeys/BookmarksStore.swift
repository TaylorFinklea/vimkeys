import Foundation

/// Cache + filesystem watcher fronting the two bookmark sources:
///
/// 1. **App Group container** — JSON dropped by VimKeysSafariExtension
///    whenever Safari's bookmarks change. The live-sync path; preferred
///    when present. Requires the user to enable the extension in Safari
///    → Settings → Extensions (and for the App Group
///    `group.io.taylorfinklea.vimkeys` to be registered on
///    developer.apple.com for team K7CBQW6MPG).
/// 2. **User-exported HTML** at `~/Documents/VimKeys/bookmarks.html`.
///    The fallback path; always available with no extension setup.
///
/// The store watches both source directories. On any filesystem event
/// it re-reads, preferring container over HTML. This way the extension
/// silently upgrades the experience when present, and disabling it
/// (or never enabling it) gracefully degrades to the export workflow.
///
/// **Why watch the directory, not the file?** Safari's export uses an
/// atomic write-then-rename; the file descriptor for the old inode goes
/// stale and the rename event doesn't fire on the new one. Watching the
/// parent directory survives the swap. The container path uses the same
/// pattern for parallel reasons.
final class BookmarksStore: @unchecked Sendable {
    static let shared = BookmarksStore()

    /// App Group identifier matching the extension. Duplicated rather
    /// than imported because the extension is a separate target and the
    /// main app can't link its module.
    static let appGroupIdentifier = "group.io.taylorfinklea.vimkeys"
    static let containerFileName = "bookmarks.json"

    private let htmlPath: URL
    private let containerPath: URL?
    private let lock = NSLock()
    private var cached: Result<[SafariBookmarks.Entry], SafariBookmarks.ReadError>
    private var htmlSource: DispatchSourceFileSystemObject?
    private var htmlFD: Int32 = -1
    private var containerSource: DispatchSourceFileSystemObject?
    private var containerFD: Int32 = -1
    private var pendingRefresh: DispatchWorkItem?
    private let refreshQueue: DispatchQueue

    init(
        htmlPath: URL = SafariBookmarks.defaultPath,
        containerPath: URL? = BookmarksStore.defaultContainerPath
    ) {
        self.htmlPath = htmlPath
        self.containerPath = containerPath
        self.cached = .failure(.fileMissing)
        self.refreshQueue = DispatchQueue(label: "io.taylorfinklea.vimkeys.bookmarks-store")
    }

    /// Where the Safari Web Extension drops its JSON snapshot. Nil when
    /// the App Group isn't registered for this build — Debug builds
    /// always, and Release builds where the user hasn't completed the
    /// developer.apple.com setup. `nil` here means "skip the container
    /// path entirely; just use HTML".
    static var defaultContainerPath: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )?.appendingPathComponent(containerFileName)
    }

    /// HTML bookmarks folder (parent of `bookmarks.html`). Surfaced so
    /// the status menu's "Open Bookmarks Folder" button has a stable
    /// URL.
    var folder: URL {
        htmlPath.deletingLastPathComponent()
    }

    /// True when the extension's container is wired up (i.e. App Group
    /// available AND the JSON file exists). Useful as a UI hint: when
    /// false, surface the "export your bookmarks" path; when true, the
    /// extension is doing its job.
    var isUsingExtension: Bool {
        guard let container = containerPath else { return false }
        return FileManager.default.fileExists(atPath: container.path)
    }

    /// Returns the most-recently-cached read result. Cheap — no disk I/O.
    func current() -> Result<[SafariBookmarks.Entry], SafariBookmarks.ReadError> {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Start watching both source directories and seed the cache.
    /// Idempotent.
    func start() {
        ensureDirectoryExists()
        refresh()
        attachHTMLWatcher()
        attachContainerWatcher()
    }

    /// Force a re-read. Container preferred over HTML when present.
    func refresh() {
        let result: Result<[SafariBookmarks.Entry], SafariBookmarks.ReadError>
        if let container = containerPath,
           FileManager.default.fileExists(atPath: container.path) {
            result = SafariBookmarks.readJSON(at: container)
        } else {
            result = SafariBookmarks.read(at: htmlPath)
        }
        lock.lock()
        cached = result
        lock.unlock()
    }

    /// Tear both watchers down — used by tests; production code keeps
    /// the singleton alive for the app lifetime.
    func stop() {
        htmlSource?.cancel()
        htmlSource = nil
        containerSource?.cancel()
        containerSource = nil
    }

    private func ensureDirectoryExists() {
        // Best-effort: ~/Documents is unprivileged for non-sandboxed
        // apps. If create fails (read-only home, weird perms), the
        // watcher path below silently no-ops and the vomnibar surfaces
        // a "file missing" message when the user presses `b`.
        let dir = folder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func attachHTMLWatcher() {
        guard htmlSource == nil else { return }
        let result = openDirectoryWatcher(at: folder.path)
        guard let result else { return }
        htmlFD = result.fd
        htmlSource = result.source
    }

    private func attachContainerWatcher() {
        guard containerSource == nil,
              let container = containerPath else { return }
        let result = openDirectoryWatcher(at: container.deletingLastPathComponent().path)
        guard let result else { return }
        containerFD = result.fd
        containerSource = result.source
    }

    private func openDirectoryWatcher(at path: String)
        -> (fd: Int32, source: DispatchSourceFileSystemObject)?
    {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: refreshQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRefresh()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return (fd, source)
    }

    /// Debounce — Safari's export emits several directory events
    /// back-to-back. Without coalescing we'd re-parse the file 3-4
    /// times per export.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        pendingRefresh = work
        refreshQueue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }
}
