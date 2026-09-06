import AppKit
import SpotliteCore

/// A row in the results list. Apps, the calculator, and the self-indexed Settings entry
/// all flow through the same cursor, Enter handling and rendering.
enum ResultItem {
    case app(MatchResult)
    case calculation(value: Double)
    case settings

    var title: String {
        switch self {
        case .app(let match): return match.entry.name
        case .calculation(let value): return Calculator.format(value)
        case .settings: return "Spotlite Settings"
        }
    }

    /// Character indices to embolden — the matched characters of a fuzzy hit.
    var highlighted: [Int] {
        if case .app(let match) = self { return match.positions }
        return []
    }

    var detail: String? {
        switch self {
        case .calculation: return "return to copy"
        case .settings: return "preferences"
        case .app: return nil
        }
    }

    var icon: NSImage? {
        switch self {
        case .app(let match):
            return IconCache.shared.icon(for: match.entry.url)
        case .calculation:
            return ResultItem.calculationIcon
        case .settings:
            return ResultItem.settingsIcon
        }
    }

    // Built once rather than per row render: `icon` is read every time a row is configured.
    private static let calculationIcon = symbol("equal.square")
    private static let settingsIcon = symbol("gearshape")

    private static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
