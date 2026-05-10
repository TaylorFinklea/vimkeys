import Foundation

/// AX attributes the role classifier looks at, captured into a value type
/// so the classification logic can be unit-tested without spinning up an
/// `AXUIElement`. Field names mirror the AX attribute names verbatim.
struct AXRoleSnapshot: Equatable {
    var role: String?
    var subrole: String?
    var isEditableAttribute: Bool?

    init(role: String? = nil, subrole: String? = nil, isEditableAttribute: Bool? = nil) {
        self.role = role
        self.subrole = subrole
        self.isEditableAttribute = isEditableAttribute
    }
}

/// AX role / subrole strings VimKeys treats as "user is typing into an
/// editable field." String literals (rather than the imported
/// `kAXTextFieldRole` etc. CFString constants) so the classifier and its
/// unit tests stay portable across SDK header churn.
enum AXRoleConstants {
    static let textField = "AXTextField"
    static let textArea = "AXTextArea"
    static let comboBox = "AXComboBox"
    static let secureTextField = "AXSecureTextField"

    /// Custom Safari attribute set on content-editable WebKit elements.
    /// Not in the standard AX role table; queried separately.
    static let editableAttribute = "AXEditable"
}

/// Pure mapping from an `AXRoleSnapshot` to "is the focused element a text
/// input?" Used by `AXFocusObserver` to decide whether to emit
/// `isEditable=true` / `false`.
///
/// Returns true when:
/// - role is `AXTextField`, `AXTextArea`, or `AXComboBox`, OR
/// - subrole is `AXSecureTextField`, OR
/// - `AXEditable` attribute is true (Safari content-editable).
func isEditableFocus(_ snapshot: AXRoleSnapshot) -> Bool {
    if snapshot.isEditableAttribute == true {
        return true
    }
    switch snapshot.role {
    case AXRoleConstants.textField, AXRoleConstants.textArea, AXRoleConstants.comboBox:
        return true
    default:
        break
    }
    if snapshot.subrole == AXRoleConstants.secureTextField {
        return true
    }
    return false
}
