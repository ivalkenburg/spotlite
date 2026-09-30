import Foundation
import Testing
@testable import SpotliteCore

@Suite("Conversions")
struct ConversionTests {
    private let locale = Locale(identifier: "en_US")

    @Test func integersStayExactAcrossAllBases() {
        #expect(QuickConversion.evaluate("255 to hex") == "0xff")
        #expect(QuickConversion.evaluate("0xff to binary") == "0b11111111")
        #expect(QuickConversion.evaluate("101010 binary to decimal") == "42")
        #expect(QuickConversion.evaluate("0o77 in decimal") == "63")
        #expect(QuickConversion.evaluate("-0xff to octal") == "-0o377")
        #expect(QuickConversion.evaluate("+42 to hex") == "0x2a")
        #expect(QuickConversion.evaluate("-0 to binary") == "0b0")
        #expect(QuickConversion.evaluate("18446744073709551615 to hex") == "0xffffffffffffffff")
        #expect(QuickConversion.evaluate("0xffffffffffffffff to decimal") == "18446744073709551615")
        #expect(QuickConversion.evaluate("-9223372036854775808 to hex") == "-0x8000000000000000")
        #expect(QuickConversion.evaluate("9007199254740993 to decimal") == "9007199254740993")
    }

    @Test func rejectsInvalidIntegersAndOverflow() {
        for query in ["18446744073709551616 to hex", "0x10000000000000000 to decimal",
                      "0b102 to decimal", "0x to decimal", "1.5 to hex", "2+2 to hex",
                      "0xff binary to decimal", "42 to base3", "--42 to hex", "ff to decimal"] {
            #expect(QuickConversion.evaluate(query) == nil, "\(query)")
        }
    }

    @Test func coversEveryDimensionAndTemperatureOffsets() {
        #expect(UnitConversion.convert("1 foot", to: "cm", locale: locale) == "30.48 cm")
        #expect(UnitConversion.convert("1 lb", to: "grams", locale: locale) == "453.59237 g")
        #expect(UnitConversion.convert("32 f", to: "celsius", locale: locale) == "0 °C")
        #expect(UnitConversion.convert("100 °C", to: "°F", locale: locale) == "212 °F")
        #expect(UnitConversion.convert("0 kelvin", to: "celsius", locale: locale) == "-273.15 °C")
        #expect(UnitConversion.convert("1 hectare", to: "m2", locale: locale) == "10,000 m²")
        #expect(UnitConversion.convert("1 litre", to: "ml", locale: locale) == "1,000 mL")
        #expect(UnitConversion.convert("36 kph", to: "m/s", locale: locale) == "10 m/s")
        #expect(UnitConversion.convert("1 US gal", to: "L", locale: locale) == "3.785411784 L")
        #expect(UnitConversion.convert("1 imperial gal", to: "L", locale: locale) == "4.54609 L")
        #expect(UnitConversion.convert("1e-15 m", to: "m", locale: locale) != "0 m")
        #expect(UnitConversion.convert("1e3 m", to: "km", locale: locale) == "1 km")
        #expect(UnitConversion.convert("1 FT", to: " CM ", locale: Locale(identifier: "nl_NL")) == "30,48 cm")
    }

    @Test func preservesSmallValuesAndAvoidsIntermediateRangeErrors() throws {
        func amount(_ source: String, to target: String) throws -> Double {
            let result = try #require(UnitConversion.convert(source, to: target, locale: locale))
            let number = try #require(result.split(separator: " ").first)
            return try #require(Double(number.replacingOccurrences(of: ",", with: "")))
        }
        #expect(try amount("1e-15 K", to: "K") == 1e-15)
        #expect(try amount("1e-15 C", to: "C") == 1e-15)
        #expect(try amount("1e-15 F", to: "F") == 1e-15)
        #expect(try amount("1e-15 C", to: "F") == 32)
        #expect(try amount("32.00000000000001 F", to: "C") > 0)
        #expect(try amount("1e308 km", to: "km") == 1e308)
        let large = try amount("1e308 km", to: "mi")
        #expect(large.isFinite && abs(large / 1e308 - 1 / 1.609344) < 1e-9)
        #expect(try amount("1e-320 nm", to: "um") > 0)
        #expect(UnitConversion.convert("-1e-11 K", to: "C", locale: locale) == nil)
        #expect(UnitConversion.convert("-273.150000001 C", to: "K", locale: locale) == nil)
        #expect(UnitConversion.convert("-459.670000001 F", to: "K", locale: locale) == nil)
        #expect(UnitConversion.convert("-459.67 F", to: "K", locale: locale) == "0 K")
        #expect(UnitConversion.convert("-273.15 C", to: "K", locale: locale) == "0 K")
    }

    @Test func acceptsExplicitQueriesAndMultiwordUnits() {
        #expect(QuickConversion.evaluate("10 km to miles")?.hasSuffix(" mi") == true)
        #expect(QuickConversion.evaluate("10 in to cm")?.hasSuffix(" cm") == true)
        #expect(QuickConversion.evaluate("10 in in cm")?.hasSuffix(" cm") == true)
        #expect(QuickConversion.evaluate(" 1 square foot to square meters ")?.hasSuffix(" m²") == true)
        #expect(QuickConversion.evaluate("1 US fluid ounce to milliliters")?.hasSuffix(" mL") == true)
    }

    @Test func rejectsAmbiguityDimensionsNonfiniteAndLongInput() {
        for query in ["10 gallons to L", "1 L to pint", "1 oz to L", "1 cup to ml",
                      "10 km to kg", "nan m to cm", "inf m to cm", "1e309 m to cm",
                      "5 * 2 km to miles", "-1 K to c", "10 km", "Safari", "uuid",
                      String(repeating: "1", count: 300) + " m to cm"] {
            #expect(QuickConversion.evaluate(query) == nil, "\(query)")
        }
    }

    @Test func conversionLeadsAndSuppressesWebSearch() throws {
        let results = SearchResults.build(for: "255 to hex", corpus: .empty, matcher: Matcher(),
                                          frecency: Frecency(), webSearch: .google)
        #expect(results.count == 1)
        guard case .conversion(let expression, let result) = try #require(results.first) else {
            Issue.record("Expected conversion card"); return
        }
        #expect(expression == "255 to hex")
        #expect(result == "0xff")
    }
}
