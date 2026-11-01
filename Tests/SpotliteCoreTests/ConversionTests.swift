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

    @Test func signsPrefixesAndExplicitBases() {
        #expect(QuickConversion.evaluate("+10 to hex") == "0xa")
        #expect(QuickConversion.evaluate("-255 to hex") == "-0xff")
        #expect(QuickConversion.evaluate("-0 to hex") == "0x0")
        #expect(QuickConversion.evaluate("ff hex to dec") == "255")
        #expect(QuickConversion.evaluate("0xff hex to dec") == "255")
        #expect(QuickConversion.evaluate("0xff binary to dec") == nil)
        #expect(QuickConversion.evaluate("--5 to hex") == nil)
    }

    @Test func toWinsOverInAndTheLastSeparatorSplits() {
        #expect(UnitConversion.convert("5 in", to: "cm", locale: locale) == "12.7 cm")
        #expect(QuickConversion.evaluate("255 in hex") == "0xff")
        #expect(QuickConversion.evaluate("255 in to hex") == nil)
    }

    @Test func absoluteZeroIsTheFloorOfEveryScale() {
        #expect(UnitConversion.convert("-273.15 c", to: "k", locale: locale) == "0 K")
        #expect(UnitConversion.convert("0 k", to: "f", locale: locale) == "-459.67 °F")
        #expect(UnitConversion.convert("-273.16 c", to: "k", locale: locale) == nil)
        #expect(UnitConversion.convert("-0.01 k", to: "c", locale: locale) == nil)
        #expect(UnitConversion.convert("-459.68 f", to: "c", locale: locale) == nil)
    }

    @Test func aUnitConvertsToItselfUnchanged() {
        #expect(UnitConversion.convert("5 km", to: "kilometers", locale: locale) == "5 km")
        #expect(UnitConversion.convert("98.6 f", to: "fahrenheit", locale: locale) == "98.6 °F")
    }

    /// Each constant against its legal definition, so a mistyped digit cannot hide in the table.
    @Test(arguments: [
        ("1 mi", "km", "1.609344 km"), ("1 nmi", "m", "1,852 m"), ("1 yd", "ft", "3 ft"),
        ("1 ft", "in", "12 in"), ("1 lb", "oz", "16 oz"), ("1 st", "lb", "14 lb"), ("1 t", "kg", "1,000 kg"),
        ("1 acre", "ft2", "43,560 ft²"), ("1 ha", "m2", "10,000 m²"), ("1 mi2", "acres", "640 acres"),
        ("1 us gal", "us qt", "4 US qt"), ("1 us qt", "us pt", "2 US pt"), ("1 us pt", "us cup", "2 US cup"),
        ("1 us cup", "us fl oz", "8 US fl oz"), ("1 imperial gal", "imperial pt", "8 imperial pt"),
        ("1 imperial pt", "imperial fl oz", "20 imperial fl oz"), ("1 l", "ml", "1,000 mL"),
        ("1 m3", "l", "1,000 L"), ("1 ft3", "in3", "1,728 in³"), ("1 knot", "km/h", "1.852 km/h"),
        ("1 mph", "ft/s", "1.466666667 ft/s"), ("36 km/h", "m/s", "10 m/s"),
    ])
    func constantsMatchTheirDefinitions(source: String, target: String, expected: String) {
        #expect(UnitConversion.convert(source, to: target, locale: locale) == expected)
    }

    @Test func spellingsNormalizeLikeSymbols() {
        #expect(UnitConversion.convert("2  Nautical   Miles", to: "KM", locale: locale) == "3.704 km")
        #expect(UnitConversion.convert("1 µm", to: "nm", locale: locale) == "1,000 nm")
        #expect(UnitConversion.convert("1 μm", to: "nm", locale: locale) == "1,000 nm")
    }
}
