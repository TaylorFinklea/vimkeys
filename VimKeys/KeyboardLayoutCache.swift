import Carbon.HIToolbox
import Foundation

/// Layout-aware replacement for the static `USKeyboardLayout` table.
///
/// Why a cache rather than direct lookup: `TISCopyCurrentKeyboardLayoutInputSource`
/// and friends assert main-thread on macOS 26 (the same assertion that
/// crashed VimKeys 0.2.0 when the engine called `NSEvent(cgEvent:).chars`
/// from the tap thread). We refresh on `@MainActor`, snapshot the raw
/// `kTISPropertyUnicodeKeyLayoutData` bytes into a Sendable buffer, and
/// the engine thread translates keycodes against that buffer via
/// `UCKeyTranslate` (which has no thread assertion — it's a pure
/// function over `UCKeyboardLayout *`).
///
/// Falls back to `USKeyboardLayout` when the layout data isn't yet
/// available (rare; only between launch and the first MainActor tick)
/// or when `UCKeyTranslate` returns garbage.
final class KeyboardLayoutCache: NSObject, @unchecked Sendable {
    /// Process-wide cache. AppModel kicks `start()` on the MainActor at
    /// launch; the engine reads via `.shared` from the tap thread.
    static let shared = KeyboardLayoutCache()

    /// Snapshot of the active input source's layout data. Atomic via
    /// `NSLock` so the engine thread can read consistently while the
    /// MainActor refreshes.
    private let lock = NSLock()
    private var layoutData: Data?
    private var keyboardType: UInt32 = 0

    @MainActor
    func start() {
        refresh()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleInputSourceChanged),
            name: NSNotification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
    }

    @MainActor
    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc
    @MainActor
    private func handleInputSourceChanged() {
        refresh()
    }

    /// Pull the current keyboard layout data from TextInputSources. Stays
    /// on the MainActor — the only safe thread.
    @MainActor
    private func refresh() {
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return
        }
        guard let layoutRef = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData) else {
            return
        }
        // `layoutRef` is a `void *` pointing at a CFData. Bridge it.
        let cfData = unsafeBitCast(layoutRef, to: CFData.self)
        let data = cfData as Data

        lock.lock()
        layoutData = data
        keyboardType = UInt32(LMGetKbdType())
        lock.unlock()
    }

    /// Translate a virtual keycode + modifier flags into the resulting
    /// character(s). Safe from any thread. Modifier-state encoding
    /// matches `UCKeyTranslate`'s upper-byte convention: shift = 0x02,
    /// command = 0x01, control = 0x10, option = 0x08, caps = 0x04.
    func characters(forKeyCode keyCode: CGKeyCode, flags: CGEventFlags) -> String? {
        lock.lock()
        let data = layoutData
        let kbType = keyboardType
        lock.unlock()

        guard let data, !data.isEmpty else {
            // Layout cache hasn't been seeded yet — fall back to the
            // static US table so the user gets *something* on first
            // keypress. Loses fidelity on non-QWERTY layouts in the
            // first ~100ms of the process; converges as soon as
            // `start()`'s `refresh()` lands.
            return USKeyboardLayout.characters(forKeyCode: keyCode, shifted: flags.contains(.maskShift))
        }

        let modifierKeyState = Self.modifierKeyState(from: flags)
        var deadKeyState: UInt32 = 0
        var unicodeChars = [UniChar](repeating: 0, count: 4)
        var actualLength = 0

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layoutPtr = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return -1
            }
            return UCKeyTranslate(
                layoutPtr,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                kbType,
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                unicodeChars.count,
                &actualLength,
                &unicodeChars
            )
        }

        guard status == noErr, actualLength > 0 else {
            return USKeyboardLayout.characters(forKeyCode: keyCode, shifted: flags.contains(.maskShift))
        }
        return String(utf16CodeUnits: unicodeChars, count: actualLength)
    }

    /// CGEventFlags → the legacy `UInt32` modifier-state byte that
    /// `UCKeyTranslate` consumes. Bit layout is `(modifiers >> 8) & 0xFF`
    /// where modifiers are the Carbon `EventRecord` bits.
    private static func modifierKeyState(from flags: CGEventFlags) -> UInt32 {
        var state: UInt32 = 0
        if flags.contains(.maskShift)        { state |= UInt32(shiftKey  >> 8) }
        if flags.contains(.maskAlphaShift)   { state |= UInt32(alphaLock >> 8) }
        if flags.contains(.maskControl)      { state |= UInt32(controlKey >> 8) }
        if flags.contains(.maskAlternate)    { state |= UInt32(optionKey >> 8) }
        if flags.contains(.maskCommand)      { state |= UInt32(cmdKey    >> 8) }
        return state
    }
}
