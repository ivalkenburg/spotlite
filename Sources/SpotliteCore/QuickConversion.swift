import Foundation

/// Only explicit conversion syntax activates this provider; ordinary app queries stay cheap.
public enum QuickConversion {
    public static func evaluate(_ query: String) -> String? {
        guard let bounded = query.boundedTrimmedWhitespace(maximumCount: Calculator.maxInputLength) else { return nil }
        guard bounded.contains(" ") else { return nil }
        let text = String(bounded).lowercased()
        guard let separator = text.range(of: " to ", options: .backwards)
                ?? text.range(of: " in ", options: .backwards) else { return nil }
        let source = String(text[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        let target = String(text[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        return BaseConversion.convert(source, to: target) ?? UnitConversion.convert(source, to: target)
    }
}
