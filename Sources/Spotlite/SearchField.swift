import AppKit
import Carbon.HIToolbox

/// Borderless field styled for the glass panel. Command-key equivalents are handled
/// here because a focused NSTextField swallows them before the panel sees them.
final class SearchField: NSTextField {
    var onCommandDigit: ((Int) -> Void)?
    var onCommandReturn: (() -> Void)?
    var onCommandQ: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 26, weight: .regular)
        textColor = .labelColor
        placeholderString = "Search"
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
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
        else { return super.performKeyEquivalent(with: event) }

        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            onCommandReturn?()
            return true
        }
        guard let chars = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        // Swallowed even when nothing can be quit, so Command-Q aimed at a result can
        // never fall through to quitting Spotlite itself.
        if chars == "q" {
            onCommandQ?()
            return true
        }
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
