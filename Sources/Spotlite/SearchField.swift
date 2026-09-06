import AppKit

/// Borderless field styled for the glass panel. Command-key equivalents are handled
/// here because a focused NSTextField swallows them before the panel sees them.
final class SearchField: NSTextField {
    var onCommandDigit: ((Int) -> Void)?

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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let chars = event.charactersIgnoringModifiers,
           let digit = Int(chars), (1...Metrics.maxVisibleRows).contains(digit) {
            onCommandDigit?(digit - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
