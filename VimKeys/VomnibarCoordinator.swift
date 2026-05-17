import AppKit
import Foundation

/// Owns the vomnibar window lifecycle + query state. Parallel to
/// `LinkHintCoordinator`: the engine forwards every keystroke during
/// `.vomnibar` mode via `.forwardVomnibarKey(chars:)`, the coordinator
/// updates the query and re-fetches suggestions, and on Enter dispatches
/// the chosen URL through `SafariBridge`.
@MainActor
final class VomnibarCoordinator {
    var onExitVomnibar: (() -> Void)?

    /// Surfaced so AppModel can flash an error banner when bookmarks
    /// reading fails (Full Disk Access not granted). Closure invoked with
    /// a short human-readable message.
    var onError: ((String) -> Void)?

    private let window = VomnibarWindow()
    private let bridge: SafariBridge
    private var flavor: VomnibarFlavor = .url(openInNewTab: false)
    private var query: String = ""
    private var tabs: [SafariBridge.Tab] = []
    private var bookmarks: [SafariBookmarks.Entry] = []

    init(bridge: SafariBridge = .shared) {
        self.bridge = bridge
    }

    /// Begin a session. Captures tabs upfront for tab-flavored sessions so
    /// the suggestion list is responsive to typing.
    func start(flavor: VomnibarFlavor) {
        self.flavor = flavor
        self.query = ""

        guard bridge.hasAccess || bridge.requestAccess() else {
            exit()
            return
        }

        switch flavor {
        case .url:
            tabs = []
            bookmarks = []
            window.viewModel.mode = .url
        case .tabs:
            tabs = bridge.openTabs()
            bookmarks = []
            window.viewModel.mode = .tabs
        case .bookmarks:
            tabs = []
            switch BookmarksStore.shared.current() {
            case .success(let entries):
                bookmarks = entries
            case .failure(let error):
                let message: String
                switch error {
                case .fileMissing:
                    message = SafariBookmarks.exportInstructions
                case .malformed:
                    message = "Couldn't parse bookmarks file. Try re-exporting from Safari."
                }
                onError?(message)
                exit()
                return
            }
            window.viewModel.mode = .url
        }

        refreshSuggestions()
        window.viewModel.query = ""
        window.viewModel.selectedIndex = 0
        window.present()
    }

    /// Forward a character keystroke from the engine. Backspace and Enter
    /// arrive here too (engine passes the keycode-derived char or sentinel).
    func handleKey(chars: String) {
        switch chars {
        case "\u{08}", "\u{7F}": // backspace / delete
            if !query.isEmpty { query.removeLast() }
        case "\u{0D}", "\u{03}": // Enter
            commit()
            return
        case "\u{0B}": // up arrow sentinel
            moveSelection(by: -1)
            return
        case "\u{0C}": // down arrow sentinel
            moveSelection(by: 1)
            return
        default:
            query.append(chars)
        }
        refreshSuggestions()
        window.viewModel.query = query
        window.viewModel.selectedIndex = 0
    }

    /// Navigate the suggestion cursor up / down. Wired to the engine for
    /// arrow-key intents.
    func moveSelection(by delta: Int) {
        let count = window.viewModel.suggestions.count
        guard count > 0 else { return }
        let next = (window.viewModel.selectedIndex + delta + count) % count
        window.viewModel.selectedIndex = next
    }

    /// Drop the window without dispatching. Called for Esc.
    func cancel() {
        cancelInternal()
        exit()
    }

    private func cancelInternal() {
        window.hide()
        window.viewModel.suggestions = []
        window.viewModel.query = ""
        query = ""
        tabs = []
    }

    private func exit() {
        cancelInternal()
        onExitVomnibar?()
    }

    private func commit() {
        let selection = window.viewModel.suggestions[safe: window.viewModel.selectedIndex]
        guard let suggestion = selection else {
            // Nothing selected: fall back to treating the raw query as a
            // URL (or search query). Matches Vimium's "open" behavior.
            if let url = candidateURL(from: query) {
                openURL(url, suggestionKind: .url)
            }
            exit()
            return
        }
        openURL(suggestion.url, suggestionKind: suggestion.kind)
        exit()
    }

    private func openURL(_ url: URL, suggestionKind: VomnibarSuggestion.Kind) {
        if case .openTab = suggestionKind {
            bridge.focusTab(matching: url)
            return
        }
        let newTab: Bool
        switch flavor {
        case .url(let openInNewTab): newTab = openInNewTab
        case .tabs: newTab = false
        case .bookmarks(let openInNewTab): newTab = openInNewTab
        }
        bridge.open(url: url, inNewTab: newTab)
    }

    // MARK: - Suggestion shaping

    private func refreshSuggestions() {
        let suggestions: [VomnibarSuggestion]
        switch flavor {
        case .url:
            suggestions = urlSuggestions(for: query)
        case .tabs:
            suggestions = tabSuggestions(for: query)
        case .bookmarks:
            suggestions = bookmarkSuggestions(for: query)
        }
        window.viewModel.suggestions = suggestions
    }

    private func bookmarkSuggestions(for query: String) -> [VomnibarSuggestion] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        let filtered: [SafariBookmarks.Entry]
        if needle.isEmpty {
            filtered = bookmarks
        } else {
            filtered = bookmarks.filter {
                $0.title.lowercased().contains(needle)
                    || $0.url.absoluteString.lowercased().contains(needle)
            }
        }
        return filtered.prefix(200).map {
            VomnibarSuggestion(title: $0.title, url: $0.url, kind: .url)
        }
    }

    private func urlSuggestions(for query: String) -> [VomnibarSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var result: [VomnibarSuggestion] = []

        if let direct = candidateURL(from: trimmed), direct.scheme != nil {
            result.append(VomnibarSuggestion(
                title: trimmed,
                url: direct,
                kind: .url
            ))
        }

        // Default to a DuckDuckGo search. Choosing DDG over Google avoids
        // the tracking-cookie chain — Vimium uses each user's default
        // engine, but we don't have a way to read Safari's preferred
        // engine via AppleScript without poking the prefs plist.
        if let search = ddgSearchURL(for: trimmed) {
            result.append(VomnibarSuggestion(
                title: "Search DuckDuckGo for \u{201C}\(trimmed)\u{201D}",
                url: search,
                kind: .search("DuckDuckGo")
            ))
        }

        return result
    }

    private func tabSuggestions(for query: String) -> [VomnibarSuggestion] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        let filtered: [SafariBridge.Tab]
        if needle.isEmpty {
            filtered = tabs
        } else {
            filtered = tabs.filter {
                $0.title.lowercased().contains(needle)
                    || $0.url.absoluteString.lowercased().contains(needle)
            }
        }
        return filtered.map {
            VomnibarSuggestion(title: $0.title, url: $0.url, kind: .openTab)
        }
    }

    private func candidateURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        // Bare host: prepend https://.
        if trimmed.contains(".") && !trimmed.contains(" "),
           let url = URL(string: "https://" + trimmed) {
            return url
        }
        return nil
    }

    private func ddgSearchURL(for query: String) -> URL? {
        guard var components = URLComponents(string: "https://duckduckgo.com/") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
