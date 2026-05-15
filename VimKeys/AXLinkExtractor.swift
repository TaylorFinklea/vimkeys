import ApplicationServices
import CoreGraphics
import Foundation

/// Walks Safari's AX subtree and harvests clickable targets (links,
/// buttons, inputs) along with their on-screen frames. Returns a flat
/// `[ExtractedTarget]` that pairs each harvested `AXUIElement` with the
/// `HintTarget` value type the state machine + overlay see.
///
/// Filtering rules:
/// - `anyClickable`: AXLink, AXButton, AXCheckBox, AXRadioButton,
///   AXPopUpButton, AXMenuButton, plus any element that supports the
///   `AXPress` action. Inputs are included too so `f` can click into a
///   search box.
/// - `textInputsOnly`: AXTextField, AXTextArea, AXSearchField, AXComboBox.
///
/// Traversal cap: `LinkHintEngine.maxTargets`. Pages with thousands of
/// links are rare; bigger pages mean tinier overlay labels, and at some
/// point scrolling becomes faster than picking from a sea of badges.
struct AXLinkExtractor {
    struct ExtractedTarget {
        let element: AXUIElement
        let hint: HintTarget
    }

    /// Roles that count as clickable for `f`/`F`. Listed verbatim as the
    /// strings AX returns (matches `kAXLinkRole` etc.).
    private static let clickableRoles: Set<String> = [
        "AXLink",
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXDisclosureTriangle",
        "AXSwitch",
    ]

    private static let inputRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXComboBox",
    ]

    /// Entry point. `pid` is Safari's process id; returns visible clickable
    /// targets ordered roughly top-to-bottom, left-to-right by their AX
    /// frame.
    static func extract(
        from pid: pid_t,
        filter: HintFilter,
        screenBounds: CGRect? = nil
    ) -> [ExtractedTarget] {
        let app = AXUIElementCreateApplication(pid)
        var collected: [ExtractedTarget] = []
        var budget = LinkHintEngine.maxTargets
        traverse(element: app, filter: filter, screenBounds: screenBounds, into: &collected, budget: &budget)

        // Sort top-to-bottom (lower y in screen space → on-screen Y goes
        // down in AX coordinates, same as Quartz). Within a row, left-to-
        // right. Matches user reading order so the lexicographic label
        // sequence intuitively assigns short labels to upper-left targets.
        collected.sort { lhs, rhs in
            if abs(lhs.hint.frame.minY - rhs.hint.frame.minY) > 4 {
                return lhs.hint.frame.minY < rhs.hint.frame.minY
            }
            return lhs.hint.frame.minX < rhs.hint.frame.minX
        }

        return collected
    }

    /// Recursive descent. Stops when budget hits zero (cap on total
    /// targets) so a 10k-link page doesn't lock the main thread for
    /// seconds.
    private static func traverse(
        element: AXUIElement,
        filter: HintFilter,
        screenBounds: CGRect?,
        into collected: inout [ExtractedTarget],
        budget: inout Int
    ) {
        guard budget > 0 else { return }

        if let target = harvestIfMatching(element: element, filter: filter, screenBounds: screenBounds) {
            collected.append(target)
            budget -= 1
        }

        var childrenRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        )
        guard result == .success,
              let array = childrenRef as? [AXUIElement] else { return }

        for child in array {
            if budget <= 0 { break }
            traverse(element: child, filter: filter, screenBounds: screenBounds, into: &collected, budget: &budget)
        }
    }

    /// Reads role + frame and decides whether this element passes the
    /// filter. Returns the wrapped `ExtractedTarget` on a hit, nil
    /// otherwise. Skips elements with zero-size frames (off-screen, hidden,
    /// not yet laid out).
    private static func harvestIfMatching(
        element: AXUIElement,
        filter: HintFilter,
        screenBounds: CGRect?
    ) -> ExtractedTarget? {
        guard let role = string(element, kAXRoleAttribute) else { return nil }

        let kind: HintTargetKind
        switch filter {
        case .anyClickable:
            if clickableRoles.contains(role) {
                kind = role == "AXLink" ? .link : .button
            } else if inputRoles.contains(role) {
                kind = .input
            } else if hasAction(element, named: kAXPressAction as CFString) {
                kind = .other
            } else {
                return nil
            }
        case .textInputsOnly:
            guard inputRoles.contains(role) else { return nil }
            kind = .input
        }

        guard let frame = readFrame(element) else { return nil }
        guard frame.width >= 2, frame.height >= 2 else { return nil }
        if let bounds = screenBounds, !bounds.intersects(frame) { return nil }

        return ExtractedTarget(
            element: element,
            hint: HintTarget(frame: frame, kind: kind)
        )
    }

    // MARK: - AX attribute helpers

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    /// Reads `AXFrame` and returns a CGRect in screen coordinates. AX
    /// stores the frame as an `AXValueRef` wrapping a CGRect; CFTypeRef
    /// has to be cast explicitly.
    private static func readFrame(_ element: AXUIElement) -> CGRect? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &ref) == .success,
              let axValue = ref else {
            return nil
        }
        guard CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let value = axValue as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }

    /// `AXPress` availability test — used as a fallback inclusion rule so
    /// custom WebKit elements (divs with click handlers, etc.) that
    /// register a press action still get hint labels.
    private static func hasAction(_ element: AXUIElement, named action: CFString) -> Bool {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String] else {
            return false
        }
        return actions.contains(action as String)
    }
}
