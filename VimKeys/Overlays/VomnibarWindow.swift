import AppKit
import SwiftUI

/// Quick-launch panel for URL / tab navigation. The user invokes it via
/// `o` / `O` / `T`; types a few characters; presses Enter to open or
/// switch. Reuses the non-activating panel pattern from `HelpOverlay` so
/// Safari never loses focus while typing — keys flow through us via the
/// global event tap, which forwards into `VomnibarCoordinator`.
@MainActor
final class VomnibarWindow: NSPanel {
    /// SwiftUI-observable state. Coordinator mutates `query` from outside;
    /// the view observes for re-render. Suggestion list filters live.
    final class ViewModel: ObservableObject {
        @Published var query: String = ""
        @Published var suggestions: [VomnibarSuggestion] = []
        @Published var selectedIndex: Int = 0
        @Published var mode: Mode = .url

        enum Mode {
            case url       // o, O — open URL / search
            case tabs      // T — switch to existing tab
        }
    }

    let viewModel = ViewModel()
    private let height: CGFloat = 360

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 360),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .modalPanel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: VomnibarContent(viewModel: viewModel))
    }

    /// Center near the top of the screen Safari is on, mimicking macOS's
    /// Spotlight placement. Falls back to the main screen.
    func present(on screen: NSScreen? = nil) {
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { orderFrontRegardless(); return }
        let frame = target.visibleFrame
        let size = self.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 120
        )
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

/// Single suggestion in the vomnibar list — title + URL + optional sub-
/// label ("Tab", "Bookmark", "Search Google"). Identifiable on URL so
/// SwiftUI can diff incrementally as the query narrows.
struct VomnibarSuggestion: Equatable, Identifiable {
    let title: String
    let url: URL
    let kind: Kind

    enum Kind: Equatable {
        case openTab
        case search(String)  // search engine label, e.g. "Search"
        case url
    }

    var id: String { "\(url.absoluteString)|\(kind)" }
}

private struct VomnibarContent: View {
    @ObservedObject var viewModel: VomnibarWindow.ViewModel

    var body: some View {
        VStack(spacing: 0) {
            queryRow
            Divider()
            suggestionList
        }
        .frame(width: 540, height: 360, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }

    private var queryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: viewModel.mode == .tabs ? "rectangle.on.rectangle" : "globe")
                .foregroundStyle(.secondary)
                .font(.title3)
            Text(viewModel.query.isEmpty ? placeholder : viewModel.query)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(viewModel.query.isEmpty ? .secondary : .primary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var placeholder: String {
        switch viewModel.mode {
        case .url:  return "Type a URL or search"
        case .tabs: return "Switch to tab"
        }
    }

    private var suggestionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionRow(
                        suggestion: suggestion,
                        selected: index == viewModel.selectedIndex
                    )
                }
            }
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: VomnibarSuggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title.isEmpty ? suggestion.url.host ?? suggestion.url.absoluteString : suggestion.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(secondary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear)
    }

    private var icon: String {
        switch suggestion.kind {
        case .openTab:  return "rectangle.on.rectangle"
        case .url:      return "link"
        case .search:   return "magnifyingglass"
        }
    }

    private var secondary: String {
        switch suggestion.kind {
        case .openTab:           return "Switch to tab \u{2014} \(suggestion.url.absoluteString)"
        case .url:               return suggestion.url.absoluteString
        case .search(let label): return "\(label): \(suggestion.url.absoluteString)"
        }
    }
}
