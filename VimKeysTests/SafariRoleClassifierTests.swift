import XCTest
@testable import VimKeys

final class SafariRoleClassifierTests: XCTestCase {
    func testTextFieldRoleIsEditable() {
        XCTAssertTrue(isEditableFocus(AXRoleSnapshot(role: AXRoleConstants.textField)))
    }

    func testTextAreaRoleIsEditable() {
        XCTAssertTrue(isEditableFocus(AXRoleSnapshot(role: AXRoleConstants.textArea)))
    }

    func testComboBoxRoleIsEditable() {
        XCTAssertTrue(isEditableFocus(AXRoleSnapshot(role: AXRoleConstants.comboBox)))
    }

    func testSecureTextFieldSubroleIsEditable() {
        let snapshot = AXRoleSnapshot(role: "AXTextField", subrole: AXRoleConstants.secureTextField)
        XCTAssertTrue(isEditableFocus(snapshot))
    }

    func testAXEditableAttributeOverridesUnknownRole() {
        let snapshot = AXRoleSnapshot(role: "AXGroup", isEditableAttribute: true)
        XCTAssertTrue(isEditableFocus(snapshot))
    }

    func testGenericRoleIsNotEditable() {
        XCTAssertFalse(isEditableFocus(AXRoleSnapshot(role: "AXButton")))
        XCTAssertFalse(isEditableFocus(AXRoleSnapshot(role: "AXLink")))
        XCTAssertFalse(isEditableFocus(AXRoleSnapshot(role: "AXGroup")))
    }

    func testEmptySnapshotIsNotEditable() {
        XCTAssertFalse(isEditableFocus(AXRoleSnapshot()))
    }

    func testAXEditableFalseDoesNotForceEditable() {
        let snapshot = AXRoleSnapshot(role: "AXGroup", isEditableAttribute: false)
        XCTAssertFalse(isEditableFocus(snapshot))
    }
}
