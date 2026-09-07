import Foundation

/// Recursive-descent arithmetic evaluator.
///
/// Hand-written rather than NSExpression: it never throws on the 95% of keystrokes
/// that aren't arithmetic, supports `^` and `%`, and builds no object graph per
/// evaluation. Every failure is a nil return, not an exception.
public enum Calculator {

    /// Caps both allocation and recursive parser depth for arbitrarily large pasted text.
    public static let maxInputLength = 256

    /// Characters that make an input worth evaluating. Without this gate, typing "1"
    /// to reach 1Password would produce a calculator row.
    private static let operators: Set<Character> = ["+", "-", "*", "/", "^", "%", "(", "×", "÷"]

    /// Evaluates `input` if it looks like arithmetic. Returns nil for anything else.
    public static func evaluate(_ input: String) -> Double? {
        guard let trimmed = input.boundedTrimmedWhitespace(maximumCount: maxInputLength),
              trimmed.count > 1,
              trimmed.contains(where: { operators.contains($0) }) else { return nil }
        guard trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == " " || operators.contains($0) || $0 == ")" })
        else { return nil }

        var parser = Parser(Array(trimmed))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// Formats a result for display: grouped thousands, up to 10 significant figures,
    /// trailing zeros trimmed so 4/2 reads as "2" rather than "2.0000000".
    ///
    /// Output follows the user's locale, so a European system shows "3,5". Input is
    /// parsed with "." as the decimal separator regardless — the asymmetry is
    /// deliberate, since "1,5" is far more often a mistyped thousands separator.
    public static func format(_ value: Double, locale: Locale = .current) -> String {
        // Reused for the common case: a NumberFormatter costs far more to build than to
        // use, and this runs on every row render while a calculation is on screen.
        let formatter = (locale == .current) ? currentLocaleFormatter : makeFormatter(locale)
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Only ever touched from the main thread (row rendering); tests pass an explicit
    /// locale and get their own instance.
    private static let currentLocaleFormatter = makeFormatter(.current)

    private static func makeFormatter(_ locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 10
        return formatter
    }

    // MARK: - Grammar

    private struct Parser {
        let chars: [Character]
        var pos = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool {
            mutating get {
                skipSpaces()
                return pos >= chars.count
            }
        }

        mutating func skipSpaces() {
            while pos < chars.count, chars[pos] == " " { pos += 1 }
        }

        mutating func peek() -> Character? {
            skipSpaces()
            return pos < chars.count ? chars[pos] : nil
        }

        /// expression := term (('+' | '-') term)*
        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                pos += 1
                guard let rhs = term() else { return nil }
                value = (op == "+") ? value + rhs : value - rhs
            }
            return value
        }

        /// term := power (('*' | '/' | '%') power)*
        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" || op == "×" || op == "÷" {
                pos += 1
                guard let rhs = power() else { return nil }
                switch op {
                case "*", "×": value *= rhs
                case "/", "÷":
                    guard rhs != 0 else { return nil }
                    value /= rhs
                default:
                    guard rhs != 0 else { return nil }
                    value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        /// power := unary ('^' power)?  — right associative, so 2^3^2 is 2^(3^2).
        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if let op = peek(), op == "^" {
                pos += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        /// unary := ('-' | '+')? primary
        mutating func unary() -> Double? {
            guard let op = peek() else { return nil }
            if op == "-" {
                pos += 1
                guard let value = unary() else { return nil }
                return -value
            }
            if op == "+" {
                pos += 1
                return unary()
            }
            return primary()
        }

        /// primary := number | '(' expression ')'
        mutating func primary() -> Double? {
            guard let ch = peek() else { return nil }
            if ch == "(" {
                pos += 1
                guard let value = expression(), peek() == ")" else { return nil }
                pos += 1
                return value
            }
            return number()
        }

        mutating func number() -> Double? {
            skipSpaces()
            let start = pos
            while pos < chars.count, chars[pos].isNumber { pos += 1 }
            if pos < chars.count, chars[pos] == "." {
                pos += 1
                while pos < chars.count, chars[pos].isNumber { pos += 1 }
            }
            guard pos > start else { return nil }
            return Double(String(chars[start..<pos]))
        }
    }
}
