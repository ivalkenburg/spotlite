import Foundation

/// Recursive-descent arithmetic evaluator.
///
/// Hand-written rather than NSExpression: it never throws on the 95% of keystrokes
/// that aren't arithmetic, supports `^` and `%`, and builds no object graph per
/// evaluation. Every failure is a nil return, not an exception.
///
/// Beyond the operators it knows functions written with parentheses (`sqrt(2)`,
/// `sin(pi/2)`, trigonometry in radians), `√` as a prefix, the constants `pi`, `π` and
/// `e`, `ans` for the previous result, and `0x`, `0b` and `0o` integer literals.
public enum Calculator {

    /// Caps both allocation and recursive parser depth for arbitrarily large pasted text.
    public static let maxInputLength = 256

    /// Characters that make an input worth evaluating. Without this gate, typing "1"
    /// to reach 1Password would produce a calculator row, and "pi" or "e" typed toward
    /// an app name would too.
    private static let operators: Set<Character> = ["+", "-", "*", "/", "^", "%", "(", "×", "÷", "√"]

    /// Evaluates `input` if it looks like arithmetic. Returns nil for anything else.
    /// - Parameter previous: What `ans` stands for; without one, `ans` is unknown.
    public static func evaluate(_ input: String, previous: Double? = nil) -> Double? {
        guard let trimmed = input.boundedTrimmedWhitespace(maximumCount: maxInputLength),
              trimmed.count > 1,
              trimmed.contains(where: { operators.contains($0) }) else { return nil }
        let chars = Array(trimmed.lowercased())
        guard chars.allSatisfy({
            $0.isNumber || ("a"..."z").contains($0) || $0 == "π" || $0 == "." || $0 == " "
                || $0 == ")" || operators.contains($0)
        }) else { return nil }

        var parser = Parser(chars, previous: previous)
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
        let previous: Double?
        var pos = 0

        init(_ chars: [Character], previous: Double?) {
            self.chars = chars
            self.previous = previous
        }

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

        /// term := unary (('*' | '/' | '%') unary)*
        mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" || op == "×" || op == "÷" {
                pos += 1
                guard let rhs = unary() else { return nil }
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

        /// power := primary ('^' unary)? — right associative, so 2^3^2 is 2^(3^2).
        /// A leading sign belongs outside the power: -2^2 is -(2^2), while 2^-2
        /// still accepts a signed exponent.
        mutating func power() -> Double? {
            guard let base = primary() else { return nil }
            if let op = peek(), op == "^" {
                pos += 1
                guard let exponent = unary() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        /// unary := ('-' | '+' | '√') unary | power
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
            if op == "√" {
                pos += 1
                guard let value = unary() else { return nil }
                return value.squareRoot()
            }
            return power()
        }

        /// primary := number | name | name '(' expression ')' | '(' expression ')'
        mutating func primary() -> Double? {
            guard let ch = peek() else { return nil }
            if ch == "(" { return parenthesized() }
            if ch == "π" {
                pos += 1
                return .pi
            }
            if ("a"..."z").contains(ch) { return named() }
            return number()
        }

        mutating func parenthesized() -> Double? {
            guard peek() == "(" else { return nil }
            pos += 1
            guard let value = expression(), peek() == ")" else { return nil }
            pos += 1
            return value
        }

        /// A constant, or a function applied to a parenthesized argument. Domain errors
        /// such as `sqrt(-1)` yield NaN, which the final finiteness check rejects.
        mutating func named() -> Double? {
            let start = pos
            while pos < chars.count, ("a"..."z").contains(chars[pos]) || chars[pos].isNumber { pos += 1 }
            let name = String(chars[start..<pos])

            switch name {
            case "pi": return .pi
            case "e": return M_E
            case "ans": return previous
            default: break
            }
            guard let function = Parser.functions[name], let argument = parenthesized() else { return nil }
            return function(argument)
        }

        static let functions: [String: @Sendable (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "cbrt": cbrt, "abs": { abs($0) },
            "round": { $0.rounded() }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
            "exp": exp, "ln": log, "log": log10, "log10": log10, "log2": log2,
            "sin": sin, "cos": cos, "tan": tan, "asin": asin, "acos": acos, "atan": atan,
        ]

        mutating func number() -> Double? {
            skipSpaces()
            if let value = prefixedInteger() { return value }
            let start = pos
            while pos < chars.count, chars[pos].isNumber { pos += 1 }
            if pos < chars.count, chars[pos] == "." {
                pos += 1
                while pos < chars.count, chars[pos].isNumber { pos += 1 }
            }
            guard pos > start else { return nil }
            return Double(String(chars[start..<pos]))
        }

        /// `0x1f`, `0b101` or `0o17`. Nil, consuming nothing, when there is no prefix.
        mutating func prefixedInteger() -> Double? {
            guard pos + 1 < chars.count, chars[pos] == "0" else { return nil }
            let radix: Int
            switch chars[pos + 1] {
            case "x": radix = 16
            case "b": radix = 2
            case "o": radix = 8
            default: return nil
            }
            var end = pos + 2
            while end < chars.count, chars[end].isASCII, chars[end].isHexDigit { end += 1 }
            // Beyond 64 bits the literal is rejected rather than silently rounded.
            guard end > pos + 2, let value = UInt64(String(chars[(pos + 2)..<end]), radix: radix)
            else { return nil }
            pos = end
            return Double(value)
        }
    }
}
