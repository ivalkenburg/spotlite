import Foundation

/// Offline conversions using scale ratios. Temperature references Celsius zero.
public enum UnitConversion {
    private enum Dimension { case length, mass, temperature, area, volume, speed }
    private struct Unit {
        let dimension: Dimension
        let symbol: String
        let scale: Double
        let reference: Double
        let minimum: Double?
    }

    public static func convert(_ source: String, to target: String, locale: Locale = .current) -> String? {
        let parts = source.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, let value = Double(parts[0]), value.isFinite,
              let from = units[normalize(String(parts[1]))], let to = units[normalize(target)],
              from.dimension == to.dimension else { return nil }
        if let minimum = from.minimum, value < minimum { return nil }
        let converted: Double
        if from.symbol == to.symbol {
            converted = value
        } else if let minimum = from.minimum, value == minimum, let targetMinimum = to.minimum {
            // Keep absolute-zero endpoints exact, rather than retaining roundoff residue.
            converted = targetMinimum
        } else {
            // Ratios avoid an overflowing/underflowing intermediate SI value. Relative
            // temperature references preserve small values around 0 °C and 32 °F.
            converted = (value - from.reference) * (from.scale / to.scale) + to.reference
        }
        guard converted.isFinite else { return nil }
        return Calculator.format(converted, locale: locale) + " " + to.symbol
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let units: [String: Unit] = {
        var result: [String: Unit] = [:]
        func add(_ dimension: Dimension, _ symbol: String, _ scale: Double,
                 _ aliases: [String], reference: Double = 0, minimum: Double? = nil) {
            let unit = Unit(dimension: dimension, symbol: symbol, scale: scale, reference: reference, minimum: minimum)
            for name in aliases + [symbol] { result[normalize(name)] = unit }
        }
        add(.length, "m", 1, ["meter", "meters", "metre", "metres"])
        add(.length, "km", 1_000, ["kilometer", "kilometers", "kilometre", "kilometres"])
        add(.length, "cm", 0.01, ["centimeter", "centimeters", "centimetre", "centimetres"])
        add(.length, "mm", 0.001, ["millimeter", "millimeters", "millimetre", "millimetres"])
        add(.length, "µm", 1e-6, ["um", "μm", "micrometer", "micrometers", "micrometre", "micrometres"])
        add(.length, "nm", 1e-9, ["nanometer", "nanometers", "nanometre", "nanometres"])
        add(.length, "in", 0.0254, ["inch", "inches"])
        add(.length, "ft", 0.3048, ["foot", "feet"])
        add(.length, "yd", 0.9144, ["yard", "yards"])
        add(.length, "mi", 1609.344, ["mile", "miles"])
        add(.length, "nmi", 1852, ["nautical mile", "nautical miles"])

        add(.mass, "kg", 1, ["kilogram", "kilograms"])
        add(.mass, "g", 0.001, ["gram", "grams"])
        add(.mass, "mg", 1e-6, ["milligram", "milligrams"])
        add(.mass, "µg", 1e-9, ["ug", "μg", "microgram", "micrograms"])
        add(.mass, "t", 1_000, ["tonne", "tonnes", "metric ton", "metric tons"])
        add(.mass, "lb", 0.45359237, ["lbs", "pound", "pounds"])
        add(.mass, "oz", 0.028349523125, ["ounce", "ounces"])
        add(.mass, "st", 6.35029318, ["stone", "stones"])

        add(.temperature, "K", 1, ["kelvin", "kelvins"], reference: 273.15, minimum: 0)
        add(.temperature, "°C", 1, ["c", "celsius", "degc", "degrees celsius"], minimum: -273.15)
        add(.temperature, "°F", 5.0 / 9, ["f", "fahrenheit", "degf", "degrees fahrenheit"],
            reference: 32, minimum: -459.67)

        add(.area, "m²", 1, ["m2", "m^2", "square meter", "square meters", "square metre", "square metres"])
        add(.area, "km²", 1e6, ["km2", "km^2", "square kilometer", "square kilometers", "square kilometre", "square kilometres"])
        add(.area, "cm²", 1e-4, ["cm2", "cm^2", "square centimeter", "square centimeters"])
        add(.area, "mm²", 1e-6, ["mm2", "mm^2", "square millimeter", "square millimeters"])
        add(.area, "ft²", 0.09290304, ["ft2", "ft^2", "sq ft", "square foot", "square feet"])
        add(.area, "in²", 0.00064516, ["in2", "in^2", "sq in", "square inch", "square inches"])
        add(.area, "yd²", 0.83612736, ["yd2", "yd^2", "square yard", "square yards"])
        add(.area, "mi²", 2589988.110336, ["mi2", "mi^2", "square mile", "square miles"])
        add(.area, "ha", 10_000, ["hectare", "hectares"])
        add(.area, "acres", 4046.8564224, ["acre"])

        add(.volume, "L", 0.001, ["l", "liter", "liters", "litre", "litres"])
        add(.volume, "mL", 1e-6, ["ml", "milliliter", "milliliters", "millilitre", "millilitres"])
        add(.volume, "m³", 1, ["m3", "m^3", "cubic meter", "cubic meters", "cubic metre", "cubic metres"])
        add(.volume, "cm³", 1e-6, ["cm3", "cm^3", "cc", "cubic centimeter", "cubic centimeters"])
        add(.volume, "ft³", 0.028316846592, ["ft3", "ft^3", "cubic foot", "cubic feet"])
        add(.volume, "in³", 0.000016387064, ["in3", "in^3", "cubic inch", "cubic inches"])
        // No unqualified gallons, pints, cups or fluid ounces: their sizes differ by region.
        add(.volume, "US gal", 0.003785411784, ["us gallon", "us gallons"])
        add(.volume, "imperial gal", 0.00454609, ["imperial gallon", "imperial gallons", "uk gal", "uk gallon", "uk gallons"])
        add(.volume, "US qt", 0.000946352946, ["us quart", "us quarts"])
        add(.volume, "imperial qt", 0.0011365225, ["imperial quart", "imperial quarts"])
        add(.volume, "US pt", 0.000473176473, ["us pint", "us pints"])
        add(.volume, "imperial pt", 0.00056826125, ["imperial pint", "imperial pints"])
        add(.volume, "US cup", 0.0002365882365, ["us cups"])
        add(.volume, "metric cup", 0.00025, ["metric cups"])
        add(.volume, "US fl oz", 0.0000295735295625, ["us fluid ounce", "us fluid ounces"])
        add(.volume, "imperial fl oz", 0.0000284130625, ["imperial fluid ounce", "imperial fluid ounces"])

        add(.speed, "m/s", 1, ["meters per second", "metres per second", "mps"])
        add(.speed, "km/h", 1 / 3.6, ["kph", "kmh", "kilometers per hour", "kilometres per hour"])
        add(.speed, "mph", 0.44704, ["mi/h", "miles per hour"])
        add(.speed, "kn", 1852.0 / 3600, ["kt", "kts", "knot", "knots"])
        add(.speed, "ft/s", 0.3048, ["fps", "feet per second"])
        return result
    }()
}
