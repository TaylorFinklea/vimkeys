import XCTest
@testable import VimKeys

final class HelpReferenceTests: XCTestCase {
    /// Every command appears exactly once across the category sections (the
    /// fixed section is separate), each with a non-empty chord for the
    /// default table. Guards that no command is missing metadata or a chord.
    func testEveryCommandRenderedWithChord() {
        let sections = HelpReference.sections(for: .v1Default)
        let categorySections = sections.dropLast()           // drop "Fixed shortcuts"
        let entries = categorySections.flatMap(\.entries)

        XCTAssertEqual(entries.count, VimCommand.allCases.count)
        let names = Set(entries.map(\.command))
        XCTAssertEqual(names, Set(VimCommand.allCases.map(\.displayName)))
        XCTAssertFalse(entries.contains { $0.chord == "\u{2014}" }) // no unbound "—"
    }

    func testReflectsCustomRemap() {
        let custom = VimBindings.v1Default.rebinding(.scrollDown, to: .single("z"))
        let entries = HelpReference.sections(for: custom).flatMap(\.entries)
        let scrollDown = entries.first { $0.command == VimCommand.scrollDown.displayName }
        XCTAssertEqual(scrollDown?.chord, "z")
    }

    func testFixedSectionIsLastAndStatic() {
        let sections = HelpReference.sections(for: .v1Default)
        XCTAssertEqual(sections.last?.title, "Fixed shortcuts")
        XCTAssertTrue(sections.last?.entries.contains { $0.chord == "Cmd+H" } ?? false)
    }
}
