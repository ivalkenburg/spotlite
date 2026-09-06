import Foundation
import Testing
@testable import SpotliteCore

@Suite("Calculator")
struct CalculatorTests {

    @Test func evaluatesArithmetic() {
        #expect(Calculator.evaluate("2+2") == 4)
        #expect(Calculator.evaluate("10-3*2") == 4)
        #expect(Calculator.evaluate("(1+2)*3") == 9)
        #expect(Calculator.evaluate("7/2") == 3.5)
        #expect(Calculator.evaluate("2^10") == 1024)
        #expect(Calculator.evaluate("10%3") == 1)
    }

    @Test func exponentIsRightAssociative() {
        #expect(Calculator.evaluate("2^3^2") == 512)
    }

    @Test func handlesUnaryMinus() {
        #expect(Calculator.evaluate("-5+2") == -3)
        #expect(Calculator.evaluate("3*-2") == -6)
    }

    @Test func requiresAnOperator() {
        // Typing "1" to reach 1Password must not produce a calculator row.
        #expect(Calculator.evaluate("1") == nil)
        #expect(Calculator.evaluate("42") == nil)
        #expect(Calculator.evaluate("safari") == nil)
    }

    @Test func rejectsMalformedInput() {
        #expect(Calculator.evaluate("2+") == nil)
        #expect(Calculator.evaluate("(1+2") == nil)
        #expect(Calculator.evaluate("*5") == nil)
        #expect(Calculator.evaluate("2++") == nil)
        #expect(Calculator.evaluate("1+2)") == nil)
    }

    @Test func divisionByZeroProducesNoResult() {
        #expect(Calculator.evaluate("1/0") == nil)
        #expect(Calculator.evaluate("5%0") == nil)
    }

    @Test func formatsWithoutTrailingZeros() {
        // Pinned locale: format() follows the user's locale, so a bare assertion here
        // would pass or fail depending on the machine running the tests.
        let us = Locale(identifier: "en_US")
        #expect(Calculator.format(4, locale: us) == "4")
        #expect(Calculator.format(3.5, locale: us) == "3.5")
        #expect(Calculator.format(1234567, locale: us) == "1,234,567")
        #expect(Calculator.format(1.0 / 3.0, locale: us) == "0.3333333333")
    }
}
