import AppKit
import ApplicationServices
import Foundation

/// MainActor-owned glue between the engine's hint intents and the AX
/// world. Holds the live hint session: a `LinkHintEngine` plus the
/// `AXUIElement` map so we can dispatch clicks once a label commits.
///
/// Lifecycle:
/// 1. Engine emits `.requestHintTraversal` → `start(...)`.
/// 2. Engine emits `.hintKey(chars:)` for every char typed in `.hint`
///    mode → `handleKey(chars:)`.
/// 3. On a `.committed` match, the coordinator dispatches the click /
///    focus / copy action and asks the engine to exit hint mode.
/// 4. Engine emits `.dismissOverlay` (Esc) → `cancel()`.
@MainActor
final class LinkHintCoordinator {
    /// Opaque callback the coordinator pokes when a hint session ends, so
    /// the engine can step the state machine back to `.normal`. AppModel
    /// wires it to `EventTapService.exitHintMode()`.
    var onExitHintMode: (() -> Void)?

    /// Surfaces an actionable failure (mirrors `VomnibarCoordinator.onError`
    /// → `AppModel.lastError`). Used for the Accessibility-trust-missing
    /// case so `f`/`F` doing nothing isn't indistinguishable from a page
    /// with no links. AppModel wires it to the error flash.
    var onError: ((String) -> Void)?

    private let overlay = HintOverlayWindow()
    private var engine: LinkHintEngine?
    private var elementByID: [UUID: AXUIElement] = [:]
    private var openInNewTab: Bool = false
    private var copyOnly: Bool = false
    private var typedPrefix: String = ""

    /// Begin a new hint session. Captures targets from Safari's AX tree
    /// and shows the overlay. No-ops if AX trust is missing or Safari
    /// isn't frontmost.
    func start(openInNewTab: Bool, copyOnly: Bool, filter: HintFilter, alphabet: String) {
        cancelInternal()

        self.openInNewTab = openInNewTab
        self.copyOnly = copyOnly
        self.typedPrefix = ""

        guard PermissionController.hasAccessibilityTrust else {
            onError?("VimKeys needs Accessibility access to read link targets. "
                + "Grant it in System Settings \u{2192} Privacy & Security \u{2192} Accessibility.")
            exit()
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              SafariObserver.safariBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else {
            exit()
            return
        }

        let screen = currentSafariScreen()
        // `AXLinkExtractor` filters against AX-space frames, so the screen
        // bounds must be flipped from Cocoa into AX space first — otherwise
        // the visibility cull compares mismatched coordinate systems and
        // discards on-screen targets on secondary displays.
        let screenBounds = screen.map {
            ScreenCoordinates.flip($0.frame, primaryHeight: ScreenCoordinates.primaryDisplayHeight)
        }
        let extracted = AXLinkExtractor.extract(
            from: pid,
            filter: filter,
            screenBounds: screenBounds
        )

        guard !extracted.isEmpty else {
            // Empty page or AX gave us nothing — pop straight back to
            // normal mode without flashing an empty overlay.
            exit()
            return
        }

        // Special case `gi`: don't show hints, just focus the first input.
        // Saves the user a keystroke and matches Vimium's "gi" behavior.
        if filter == .textInputsOnly, let first = extracted.first {
            focusElement(first.element)
            exit()
            return
        }

        let engine = LinkHintEngine(
            alphabet: alphabet,
            targets: extracted.map(\.hint)
        )
        self.engine = engine
        self.elementByID = Dictionary(uniqueKeysWithValues: extracted.map { ($0.hint.id, $0.element) })

        overlay.viewModel.labels = engine.labels
        overlay.viewModel.typedPrefix = ""
        overlay.viewModel.matching = Set(engine.labels.map(\.target.id))
        overlay.present(on: screen)
    }

    /// Receive a single character typed during hint mode. Filters labels;
    /// on `.committed`, dispatches the action and exits hint mode.
    func handleKey(chars: String) {
        guard let engine else { return }

        // Ignore non-alphabet characters (digits, punctuation). Vimium
        // beeps; we silently swallow.
        guard chars.count == 1, let scalar = chars.first, engine.isAlphabetCharacter(scalar) else {
            return
        }

        typedPrefix.append(scalar.lowercased())
        overlay.viewModel.typedPrefix = typedPrefix

        switch engine.filter(typedPrefix: typedPrefix) {
        case .ambiguous(let matching):
            overlay.viewModel.matching = matching
        case .committed(let id):
            dispatchAction(for: id)
            exit()
        case .none:
            // Invalid sequence — drop the last char and stay in hint mode.
            typedPrefix.removeLast()
            overlay.viewModel.typedPrefix = typedPrefix
            NSSound.beep()
        }
    }

    /// Drop the overlay without dispatching. Called for Esc.
    func cancel() {
        cancelInternal()
        exit()
    }

    private func cancelInternal() {
        overlay.hide()
        overlay.viewModel.labels = []
        overlay.viewModel.matching = []
        overlay.viewModel.typedPrefix = ""
        engine = nil
        elementByID = [:]
        typedPrefix = ""
    }

    /// Tell the engine to step the state machine back to `.normal`.
    private func exit() {
        cancelInternal()
        onExitHintMode?()
    }

    // MARK: - Dispatch

    private func dispatchAction(for id: UUID) {
        guard let element = elementByID[id] else { return }

        if copyOnly {
            copyURL(of: element)
            return
        }

        if openInNewTab {
            cmdClickCenter(of: element)
        } else {
            press(element)
        }
    }

    /// `AXPress` is the cleanest path for links/buttons — the OS routes it
    /// through WebKit's native click handler and respects accessibility
    /// shortcuts. Falls back to a synthesized mouse click if `AXPress`
    /// isn't available.
    private func press(_ element: AXUIElement) {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result != .success {
            clickCenter(of: element, flags: [])
        }
    }

    /// `AXPress` can't carry modifiers, so for `F` (Cmd+click → background
    /// tab) we synthesize a Cmd-modified mouse click at the element's
    /// frame center.
    private func cmdClickCenter(of element: AXUIElement) {
        clickCenter(of: element, flags: .maskCommand)
    }

    private func clickCenter(of element: AXUIElement, flags: CGEventFlags) {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &ref) == .success,
              let axValue = ref,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return
        }
        // swiftlint:disable:next force_cast
        let value = axValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        synthesizeClick(at: point, flags: flags)
    }

    private func synthesizeClick(at point: CGPoint, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                           mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)

        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private func focusElement(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func copyURL(of element: AXUIElement) {
        // AXURL is the href on `AXLink` elements. Fall back to AXValue for
        // text fields with stable identifiers.
        var ref: CFTypeRef?
        let urlResult = AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &ref)
        if urlResult == .success, let url = ref as? URL {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            return
        }
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(title, forType: .string)
        }
    }

    /// Which screen is Safari's focused window on? We can use this to size
    /// the overlay to a single display and to scope AX traversal to
    /// visible bounds.
    private func currentSafariScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return NSScreen.main
        }
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let window = ref, CFGetTypeID(window) == AXUIElementGetTypeID() {
            // swiftlint:disable:next force_cast
            let win = window as! AXUIElement
            var frameRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, "AXFrame" as CFString, &frameRef) == .success,
               let axValue = frameRef, CFGetTypeID(axValue) == AXValueGetTypeID() {
                // swiftlint:disable:next force_cast
                let value = axValue as! AXValue
                var rect = CGRect.zero
                if AXValueGetValue(value, .cgRect, &rect) {
                    // `rect` is the window frame in AX space (top-left
                    // origin); `NSScreen.frame` is Cocoa (bottom-left).
                    // Flip before intersecting or the match only works on
                    // the primary display — a vertically-stacked secondary
                    // display would never intersect and we'd fall back to
                    // the wrong screen.
                    let cocoaRect = ScreenCoordinates.flip(
                        rect,
                        primaryHeight: ScreenCoordinates.primaryDisplayHeight
                    )
                    return NSScreen.screens.first { $0.frame.intersects(cocoaRect) } ?? NSScreen.main
                }
            }
        }
        return NSScreen.main
    }
}
