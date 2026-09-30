/// Built-in search utilities with independent visibility settings. These are not
/// indexed apps: their results come from expressions or fixed search keywords.
public enum SearchUtility: String, Codable, Sendable, CaseIterable {
    case caffeinate
    case generateUUID
    case calculator
    case unitConversion

    public var name: String {
        switch self {
        case .caffeinate: "Caffeinate"
        case .generateUUID: "Generate UUID"
        case .calculator: "Calculator"
        case .unitConversion: "Unit Conversion"
        }
    }

    public var symbolName: String {
        switch self {
        case .caffeinate: "cup.and.saucer"
        case .generateUUID: "number"
        case .calculator: "equal"
        case .unitConversion: "arrow.left.arrow.right"
        }
    }
}
