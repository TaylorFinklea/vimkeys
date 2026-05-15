import CoreGraphics
import Foundation

/// One clickable target in Safari's AX tree, plus its on-screen geometry.
/// The `id` is opaque so the state machine can refer to a target without
/// holding the `AXUIElement` (which lives in `LinkHintCoordinator`).
struct HintTarget: Equatable, Identifiable {
    let id: UUID
    let frame: CGRect
    let kind: HintTargetKind

    init(id: UUID = UUID(), frame: CGRect, kind: HintTargetKind) {
        self.id = id
        self.frame = frame
        self.kind = kind
    }
}

/// Coarse classification used for visual differentiation and for choosing
/// the dispatch path (`AXPress` for links/buttons, AX focus for inputs).
enum HintTargetKind: Equatable {
    case link
    case button
    case input
    case other
}

/// Verdict returned by `LinkHintEngine.filter(typedPrefix:)`.
enum HintMatchResult: Equatable {
    /// Multiple labels still start with the typed prefix. The set lets the
    /// overlay grey out non-matching labels.
    case ambiguous(matching: Set<UUID>)
    /// Exactly one label matches: ready to dispatch.
    case committed(UUID)
    /// Nothing matches — the typed prefix is invalid. The coordinator
    /// usually beeps and ignores the keystroke (Vimium behavior).
    case none
}

/// Pure value-type label generator + matcher. Owns the assignment of
/// alphabet labels to a list of `HintTarget`s and answers "which one did
/// the user select" as keys are typed.
///
/// Algorithm: a balanced lexicographic scheme over the alphabet.
/// - Pick the smallest label length `L` such that `K^L >= N` (where `K` is
///   the alphabet size and `N` is target count).
/// - Assign labels in lexicographic order: target 0 gets `"sa"`, target 1
///   `"sd"`, etc. (for alphabet `"sadf..."`).
/// - All labels have the same length. (Vimium varies length to optimize
///   typing — saved for V-M5+ if it matters in practice.)
struct LinkHintEngine {
    /// Generated label-target pair. Public so tests + the overlay renderer
    /// can iterate `labels` directly.
    struct Assignment: Equatable {
        let target: HintTarget
        let label: String
    }

    /// Default home-row alphabet borrowed from Vimium. 14 characters: every
    /// key reachable without leaving the home row on US-QWERTY plus a
    /// couple of stretches (`g`, `h` are home-row index; `r`, `u`, `i`,
    /// `e`, `w`, `o`, `m`, `n`, `b`, `v`, `c`, `x`, `z`, `q`, `t`, `y`,
    /// `p` excluded so they remain free for normal-mode bindings).
    static let defaultAlphabet = "sadfjkl;ehiwopvbnm"

    /// Cap on number of hints we'll generate per page. Bigger pages with
    /// thousands of links produce overlay clutter that's harder to read
    /// than just scrolling. The coordinator clamps before passing in.
    static let maxTargets = 999

    let alphabet: [Character]
    let labels: [Assignment]

    init(alphabet: String = LinkHintEngine.defaultAlphabet, targets: [HintTarget]) {
        let alpha = alphabet.isEmpty ? Array(Self.defaultAlphabet) : Array(alphabet)
        self.alphabet = alpha
        self.labels = Self.assignLabels(targets: targets, alphabet: alpha)
    }

    /// Returns the label assigned to a given target id, or `nil` if the
    /// target isn't in our table. Used by the overlay renderer.
    func label(for id: UUID) -> String? {
        labels.first(where: { $0.target.id == id })?.label
    }

    /// Returns the assignment with a given label (case-insensitive), or
    /// `nil` if no match. Used by the coordinator to resolve `.committed`
    /// IDs into clickable targets.
    func assignment(matching label: String) -> Assignment? {
        let needle = label.lowercased()
        return labels.first { $0.label.lowercased() == needle }
    }

    /// Filter the live label set by the typed prefix. Comparison is
    /// case-insensitive so Shift+letter doesn't break the match (Vimium
    /// convention; also lets users type `Sf` for `sf` without thinking).
    func filter(typedPrefix: String) -> HintMatchResult {
        let needle = typedPrefix.lowercased()
        if needle.isEmpty {
            let all = Set(labels.map { $0.target.id })
            return .ambiguous(matching: all)
        }

        let matches = labels.filter { $0.label.lowercased().hasPrefix(needle) }
        if matches.isEmpty {
            return .none
        }
        if matches.count == 1, matches[0].label.lowercased() == needle {
            return .committed(matches[0].target.id)
        }
        return .ambiguous(matching: Set(matches.map { $0.target.id }))
    }

    /// True iff `char` is a legitimate alphabet character. The coordinator
    /// uses this to decide whether to append a typed key to the prefix
    /// vs. ignore it (digits, punctuation, etc. should be ignored, not
    /// reject the entire hint session).
    func isAlphabetCharacter(_ char: Character) -> Bool {
        alphabet.contains(Character(char.lowercased()))
    }

    // MARK: - Label generation

    private static func assignLabels(
        targets: [HintTarget],
        alphabet: [Character]
    ) -> [Assignment] {
        guard !targets.isEmpty, !alphabet.isEmpty else { return [] }

        let n = targets.count
        let k = alphabet.count
        let length = labelLength(n: n, k: k)

        var result: [Assignment] = []
        result.reserveCapacity(n)

        for (index, target) in targets.enumerated() {
            result.append(Assignment(
                target: target,
                label: labelFor(index: index, length: length, alphabet: alphabet)
            ))
        }
        return result
    }

    /// Smallest `L` such that `k^L >= n`. Special-cased so n=0/1 still
    /// returns at least 1.
    static func labelLength(n: Int, k: Int) -> Int {
        guard n > 0, k > 0 else { return 1 }
        var length = 1
        var capacity = k
        while capacity < n {
            length += 1
            capacity *= k
            // Defensive: don't overflow if the caller forgets to clamp.
            if capacity > Int.max / k { break }
        }
        return length
    }

    /// Lexicographic encoding of `index` in base `k` with leading-zero
    /// padding to `length`. Index 0, length 2, alphabet `"sadf"` → `"ss"`.
    private static func labelFor(index: Int, length: Int, alphabet: [Character]) -> String {
        let k = alphabet.count
        var remaining = index
        var chars: [Character] = []
        for _ in 0..<length {
            chars.insert(alphabet[remaining % k], at: 0)
            remaining /= k
        }
        return String(chars)
    }
}
