import Foundation

/// Exact signed-magnitude conversion: never routes integers through Double.
public enum BaseConversion {
    public static func convert(_ source: String, to target: String) -> String? {
        guard let destination = radix(target) else { return nil }
        let parts = source.lowercased().split(whereSeparator: \.isWhitespace)
        guard (1...2).contains(parts.count) else { return nil }
        var digits = String(parts[0])
        let negative = digits.hasPrefix("-")
        if negative || digits.hasPrefix("+") { digits.removeFirst() }
        var base = 10
        for (prefix, candidate) in [("0x", 16), ("0b", 2), ("0o", 8)] {
            if digits.hasPrefix(prefix) {
                base = candidate
                digits.removeFirst(2)
                break
            }
        }
        if parts.count == 2 {
            guard let explicit = radix(String(parts[1])), base == 10 || base == explicit else { return nil }
            base = explicit
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let magnitude = UInt64(digits, radix: base) else { return nil }
        let prefix = switch destination {
        case 16: "0x"
        case 2: "0b"
        case 8: "0o"
        default: ""
        }
        return (negative && magnitude != 0 ? "-" : "") + prefix + String(magnitude, radix: destination)
    }

    private static func radix(_ name: String) -> Int? {
        switch name.lowercased() {
        case "decimal", "dec", "base10": 10
        case "hexadecimal", "hex", "base16": 16
        case "binary", "bin", "base2": 2
        case "octal", "oct", "base8": 8
        default: nil
        }
    }
}
