import AppKit
import Carbon.HIToolbox

/// Click-to-record shortcut field. Rejects bare keys and modifier-only chords, since
/// either would make the hotkey fire constantly or never.
@MainActor
final class HotKeyRecorder: NSButton {

    private(set) var keyCode: UInt32
    private(set) var modifiers: UInt32
    private var recording = false
    private var monitor: Any?

    /// Returns false when the chord could not be registered; the previous display and
    /// binding are retained in that case.
    var onChange: ((UInt32, UInt32) -> Bool)?

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func startRecording() {
        guard !recording else { return }
        recording = true
        title = "Press a shortcut…"

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            guard event.type == .keyDown else { return nil }

            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording()
                return nil
            }

            let carbonModifiers = HotKeyRecorder.carbonModifiers(from: event.modifierFlags)
            // A shortcut with no modifier would fire on every keystroke everywhere.
            guard carbonModifiers != 0 else {
                NSSound.beep()
                return nil
            }

            let proposedCode = UInt32(event.keyCode)
            self.stopRecording()
            guard self.onChange?(proposedCode, carbonModifiers) ?? true else {
                NSSound.beep()
                return nil
            }
            self.keyCode = proposedCode
            self.modifiers = carbonModifiers
            self.refreshTitle()
            return nil
        }
    }

    func cancelRecording() {
        guard recording else { return }
        stopRecording()
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refreshTitle()
    }

    private func refreshTitle() {
        title = HotKeyRecorder.describe(keyCode: keyCode, modifiers: modifiers)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName(keyCode)
    }

    private static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        default: break
        }

        // Ask the current keyboard layout what this key produces, so a non-QWERTY
        // layout doesn't display the wrong letter.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "Key \(code)" }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
