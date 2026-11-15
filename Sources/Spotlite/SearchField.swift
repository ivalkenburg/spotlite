import AppKit
import Carbon.HIToolbox

/// Borderless field styled for the glass panel. Command-key equivalents are handled
/// here because a focused NSTextField swallows them before the panel sees them.
final class SearchField: NSTextField {
    var onCommandDigit: ((Int) -> Void)?
    /// Return with Command and any other modifiers; false lets the event go on.
    var onCommandReturn: ((NSEvent.ModifierFlags) -> Bool)?
    /// Return with Control and Option, which the text system would type as a space.
    var onControlOptionReturn: ((NSEvent.ModifierFlags) -> Void)?
    /// Command-K; false lets the event go on.
    var onCommandK: (() -> Bool)?
    var onCommandQ: (() -> Void)?
    var onUndoHide: (() -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: Metrics.queryFontSize, weight: .regular)
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Spotlite has no Edit menu, which is where these shortcuts normally come from, so
    /// without this a focused field ignores Command-A, C, V, X and Z entirely.
    private static let editingActions: [String: Selector] = [
        "a": #selector(NSText.selectAll(_:)),
        "c": #selector(NSText.copy(_:)),
        "v": #selector(NSText.paste(_:)),
        "x": #selector(NSText.cut(_:)),
        "z": Selector(("undo:")),
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only the user-facing modifiers: keypad Enter also carries .numericPad.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isReturn = event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)
        // A plugin can bind Command with other modifiers to Return.
        if isReturn, modifiers.contains(.command), onCommandReturn?(modifiers) == true { return true }
        // Unlike ⌃↩ and ⌥↩, this chord names no command: the field editor inserts it as text.
        if isReturn, !modifiers.contains(.command), modifiers.isSuperset(of: [.control, .option]) {
            onControlOptionReturn?(modifiers)
            return true
        }
        guard modifiers == .command else { return super.performKeyEquivalent(with: event) }

        if isReturn { return true }
        guard let chars = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        // Swallowed even when nothing can be quit, so Command-Q aimed at a result can
        // never fall through to quitting Spotlite itself.
        if chars == "q" {
            onCommandQ?()
            return true
        }
        if chars == "z", onUndoHide?() == true { return true }
        if chars == "k", onCommandK?() == true { return true }
        if let action = SearchField.editingActions[chars], currentEditor() != nil {
            return NSApp.sendAction(action, to: nil, from: self)
        }
        if let digit = Int(chars), (1...9).contains(digit) {
            onCommandDigit?(digit - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
