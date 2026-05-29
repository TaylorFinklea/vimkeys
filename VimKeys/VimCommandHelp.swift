import Foundation

/// Presentation metadata for each `VimCommand`: a human label, a short
/// detail, and a grouping category. Drives the help overlay and the
/// (forthcoming) remap settings UI, so both stay in sync with the live
/// bindings instead of a hand-maintained list. The `switch` is exhaustive,
/// so adding a `VimCommand` case is a compile error until it's described.
extension VimCommand {
    enum Category: Int, CaseIterable {
        case scroll, findHistory, tabs, hints, clipboardVomnibar, mode

        var title: String {
            switch self {
            case .scroll: return "Scroll"
            case .findHistory: return "Find & history"
            case .tabs: return "Tabs"
            case .hints: return "Link hints"
            case .clipboardVomnibar: return "Clipboard & vomnibar"
            case .mode: return "Mode & suspend"
            }
        }
    }

    var category: Category { helpInfo.category }
    var displayName: String { helpInfo.name }
    var detail: String { helpInfo.detail }

    private var helpInfo: (category: Category, name: String, detail: String) {
        switch self {
        case .scrollDown: return (.scroll, "Scroll down", "3 lines per press")
        case .scrollUp: return (.scroll, "Scroll up", "3 lines per press")
        case .scrollLeft: return (.scroll, "Scroll left", "3 columns per press")
        case .scrollRight: return (.scroll, "Scroll right", "3 columns per press")
        case .halfPageDown: return (.scroll, "Half-page down", "~15 lines")
        case .halfPageUp: return (.scroll, "Half-page up", "~15 lines")
        case .top: return (.scroll, "Jump to top", "")
        case .bottom: return (.scroll, "Jump to bottom", "")

        case .find: return (.findHistory, "Find in page", "Synthesizes Cmd+F")
        case .findNext: return (.findHistory, "Find next", "Cmd+G")
        case .findPrev: return (.findHistory, "Find previous", "Cmd+Shift+G")
        case .historyBack: return (.findHistory, "History back", "Cmd+[")
        case .historyForward: return (.findHistory, "History forward", "Cmd+]")
        case .reload: return (.findHistory, "Reload", "Cmd+R")
        case .hardReload: return (.findHistory, "Hard reload", "Cmd+Option+R (needs Develop menu)")

        case .closeTab: return (.tabs, "Close current tab", "Cmd+W")
        case .reopenTab: return (.tabs, "Reopen last closed tab", "Cmd+Shift+T")

        case .hint: return (.hints, "Hint and click", "Type the label to click")
        case .hintNewTab: return (.hints, "Hint, open in new tab", "Cmd+click on selection")
        case .focusInput: return (.hints, "Focus first text input", "Skips the overlay")
        case .viewSource: return (.hints, "View source", "Cmd+Option+U")

        case .copyURL: return (.clipboardVomnibar, "Copy current URL", "Apple Events")
        case .copyHintURL: return (.clipboardVomnibar, "Copy a link via hint", "Hint, but yank instead of click")
        case .vomnibarURL: return (.clipboardVomnibar, "Open URL or search", "DuckDuckGo for non-URLs")
        case .vomnibarURLNewTab: return (.clipboardVomnibar, "Open URL or search, new tab", "")
        case .vomnibarBookmarks: return (.clipboardVomnibar, "Bookmark vomnibar", "Requires Full Disk Access")
        case .vomnibarBookmarksNewTab: return (.clipboardVomnibar, "Bookmark vomnibar, new tab", "Requires Full Disk Access")
        case .vomnibarTabs: return (.clipboardVomnibar, "Switch tab", "Filter by title or URL")
        case .openClipboard: return (.clipboardVomnibar, "Open clipboard URL", "Falls back to search")
        case .openClipboardNewTab: return (.clipboardVomnibar, "Open clipboard URL, new tab", "")

        case .enterInsert: return (.mode, "Enter insert mode", "Manual insert override")
        case .escape: return (.mode, "Exit insert / cancel prefix", "Returns to normal mode")
        case .help: return (.mode, "Show / dismiss help", "This window")
        case .suspendChord: return (.mode, "Toggle suspend on this URL", "Double-tap; cleared on navigation")
        }
    }
}

/// Builds the help-overlay reference from a live `VimBindings`, so custom
/// remaps are reflected. Pure + non-view so it can be unit-tested.
enum HelpReference {
    struct Entry: Identifiable {
        let id = UUID()
        let chord: String
        let command: String
        let detail: String
    }

    struct Section: Identifiable {
        let id = UUID()
        let title: String
        let entries: [Entry]
    }

    /// One section per category (in `Category` order), each command shown
    /// with its current chord(s), followed by a static section for the
    /// fixed shortcuts that live outside the bindings table.
    static func sections(for bindings: VimBindings) -> [Section] {
        let index = bindings.reverseIndex
        var sections = Category.allCases.map { category -> Section in
            let entries = VimCommand.allCases
                .filter { $0.category == category }
                .map { command -> Entry in
                    let chord = (index[command] ?? []).map(\.display).joined(separator: " / ")
                    return Entry(chord: chord.isEmpty ? "\u{2014}" : chord,
                                 command: command.displayName,
                                 detail: command.detail)
                }
            return Section(title: category.title, entries: entries)
        }
        sections.append(fixedSection)
        return sections
    }

    /// Shortcuts resolved by keycode in the state machine, outside the
    /// bindings table — not remappable, so listed statically.
    static let fixedSection = Section(title: "Fixed shortcuts", entries: [
        Entry(chord: "<count>", command: "Repeat next motion", detail: "5j → scroll down 5×, capped at 999"),
        Entry(chord: "Cmd+H", command: "Previous tab", detail: "Cmd+Shift+[ underneath"),
        Entry(chord: "Cmd+L", command: "Next tab", detail: "Cmd+Shift+] underneath"),
        Entry(chord: "Cmd+Shift+J", command: "Next tab group", detail: "Down the sidebar"),
        Entry(chord: "Cmd+Shift+K", command: "Previous tab group", detail: "Up the sidebar"),
        Entry(chord: "Settings \u{2192} Sites", command: "Persistent per-host disable", detail: "Suffix-matched"),
    ])

    private typealias Category = VimCommand.Category
}
