import Foundation

/// Cache + filesystem watcher fronting the two bookmark sources:
///
/// 1. **Safari's `Bookmarks.plist`** — `~/Library/Safari/Bookmarks.plist`,
///    Safari's own live bookmark store. The preferred source: always
///    fresh, no manual step. Reading it requires the user to grant
///    VimKeys Full Disk Access, since `~/Library/Safari` is TCC-protected.
/// 2. **User-exported HTML** at `~/Documents/VimKeys/bookmarks.html`.
///    The fallback path; always available with no permission grant, but
///    the user must re-export from Safari whenever bookmarks change.
///
/// The store watches both source directories. On any filesystem event it
/// re-reads, preferring the live plist over the HTML export. A user who
/// grants Full Disk Access gets always-fresh bookmarks; one who declines
/// it degrades gracefully to the export workflow.
///
/// **Why watch the directory, not the file?** Both Safari's export and
/// its `Bookmarks.plist` rewrites use an atomic write-then-rename; the
/// file descriptor for the old inode goes stale and the rename event
/// doesn't fire on the new one. Watching the parent directory survives
/// the inode swap.
final class BookmarksStore: @unchecked Sendable {
    static let shared = BookmarksStore()

    /// `~/Library/Safari/Bookmarks.plist` — Safari's own bookmark store.
    static var defaultPlistPath: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist")
    }

    /// Which source the current cache was read from.
    private enum Source {
        case plist
        case html
        case none
    }

    private let htmlPath: URL
    private let plistPath: URL?
    private let lock = NSLock()
    private var cached: Result<[SafariBookmarks.Entry], SafariBookmarks.ReadError>
    private var cachedSource: Source = .none
    private var htmlSource: DispatchSourceFileSystemObject?
    private var htmlFD: Int32 = -1
    private var plistSource: DispatchSourceFileSystemObject?
    private var plistFD: Int32 = -1
    private var pendingRefresh: DispatchWorkItem?
    private let refreshQueue: DispatchQueue

    init(
        htmlPath: URL = SafariBookmarks.defaultPath,
        plistPath: URL? = BookmarksStore.defaultPlistPath
    ) {
        self.htmlPath = htmlPath
        self.plistPath = plistPath
        self.cached = .failure(.fileMissing)
        self.refreshQueue = DispatchQueue(label: "io.taylorfinklea.vimkeys.bookmarks-store")
    }

    /// HTML bookmarks folder (parent of `bookmarks.html`). Surfaced so
    /// the status menu's "Open Bookmarks Folder" button has a stable
    /// URL.
    var folder: URL {
        htmlPath.deletingLastPathComponent()
    }

    /// True when the current cache came from Safari's live `Bookmarks.plist`
    /// rather than the HTML export. A UI hint: when false, the user is on
    /// the manual export workflow (or hasn't granted Full Disk Access).
    var isUsingLiveSync: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedSource == .plist
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
        attachPlistWatcher()
    }

    /// Force a re-read. The live plist is preferred over the HTML export.
    func refresh() {
        let outcome = readPreferredSource()
        lock.lock()
        cached = outcome.result
        cachedSource = outcome.source
        lock.unlock()
    }

    /// Reads the live plist first, falling back to the HTML export. When
    /// both fail, surfaces whichever error is most actionable: a denied
    /// plist read (`.permissionDenied` → grant Full Disk Access) outranks
    /// the HTML error (→ export your bookmarks), since live sync is the
    /// path we want users on.
    private func readPreferredSource()
        -> (result: Result<[SafariBookmarks.Entry], SafariBookmarks.ReadError>, source: Source)
    {
        guard let plistPath else {
            return (SafariBookmarks.read(at: htmlPath), sourceForHTMLOnly())
        }

        let plistResult = SafariBookmarks.readPlist(at: plistPath)
        if case .success = plistResult {
            return (plistResult, .plist)
        }

        let htmlResult = SafariBookmarks.read(at: htmlPath)
        if case .success = htmlResult {
            return (htmlResult, .html)
        }
        if case .failure(.permissionDenied) = plistResult {
            return (.failure(.permissionDenied), .none)
        }
        return (htmlResult, .none)
    }

    private func sourceForHTMLOnly() -> Source {
        if case .success = SafariBookmarks.read(at: htmlPath) {
            return .html
        }
        return .none
    }

    /// Tear both watchers down — used by tests; production code keeps
    /// the singleton alive for the app lifetime.
    func stop() {
        htmlSource?.cancel()
        htmlSource = nil
        plistSource?.cancel()
        plistSource = nil
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

    /// Watches `~/Library/Safari`. When Full Disk Access isn't granted,
    /// `open()` on that directory fails and the watcher silently no-ops —
    /// `refresh()` still attempts the read and surfaces `.permissionDenied`.
    private func attachPlistWatcher() {
        guard plistSource == nil, let plistPath else { return }
        let result = openDirectoryWatcher(at: plistPath.deletingLastPathComponent().path)
        guard let result else { return }
        plistFD = result.fd
        plistSource = result.source
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

    /// Debounce — an atomic replace emits several directory events
    /// back-to-back. Without coalescing we'd re-parse the file 3-4
    /// times per write.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        pendingRefresh = work
        refreshQueue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }
}
