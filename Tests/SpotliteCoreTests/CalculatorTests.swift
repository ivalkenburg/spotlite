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

    @Test func rejectsPathologicallyLargePastedExpressions() {
        let input = String(repeating: "-", count: 100_000) + "1+1"
        #expect(Calculator.evaluate(input) == nil)
    }

    @Test func inputLimitIsAppliedAfterTrimmingWithoutChangingAcceptedInput() {
        let padding = String(repeating: " ", count: 10_000)
        #expect(Calculator.evaluate(padding + "1+1" + padding) == 2)
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

@Suite("Calculator functions and constants")
struct CalculatorFunctionTests {

    private func close(_ input: String, _ expected: Double, previous: Double? = nil) -> Bool {
        guard let value = Calculator.evaluate(input, previous: previous) else { return false }
        return abs(value - expected) < 1e-9
    }

    @Test func evaluatesFunctions() {
        #expect(Calculator.evaluate("sqrt(16)") == 4)
        #expect(Calculator.evaluate("abs(-3)") == 3)
        #expect(Calculator.evaluate("floor(2.7)+ceil(2.2)") == 5)
        #expect(Calculator.evaluate("log(1000)") == 3)
        #expect(Calculator.evaluate("log2(8)") == 3)
        #expect(close("ln(e^2)", 2))
        #expect(close("sin(pi/2)", 1))
        #expect(close("cos(0)", 1))
    }

    @Test func functionNamesIgnoreCase() {
        #expect(Calculator.evaluate("SQRT(9)") == 3)
    }

    @Test func squareRootSign() {
        #expect(Calculator.evaluate("√16") == 4)
        #expect(Calculator.evaluate("√(9+7)") == 4)
        #expect(Calculator.evaluate("2*√4") == 4)
    }

    @Test func constants() {
        #expect(close("2*pi", 2 * .pi))
        #expect(close("π/2", .pi / 2))
        #expect(close("e*1", M_E))
    }

    @Test func constantsAloneAreNotCalculations() {
        // "pi" or "e" typed toward an app name must stay a search.
        #expect(Calculator.evaluate("pi") == nil)
        #expect(Calculator.evaluate("e") == nil)
    }

    @Test func radixLiterals() {
        #expect(Calculator.evaluate("0xff+1") == 256)
        #expect(Calculator.evaluate("0b1010*1") == 10)
        #expect(Calculator.evaluate("0o17+0") == 15)
        #expect(Calculator.evaluate("0x+1") == nil)
        #expect(Calculator.evaluate("0b12+1") == nil)
    }

    @Test func ansIsThePreviousResult() {
        #expect(Calculator.evaluate("ans*2", previous: 21) == 42)
        #expect(Calculator.evaluate("ans*2") == nil)
    }

    @Test func domainErrorsProduceNoResult() {
        #expect(Calculator.evaluate("sqrt(-1)") == nil)
        #expect(Calculator.evaluate("ln(0)") == nil)
        #expect(Calculator.evaluate("√-4") == nil)
    }

    @Test func rejectsUnknownNamesAndMissingParentheses() {
        #expect(Calculator.evaluate("foo(2)") == nil)
        #expect(Calculator.evaluate("sqrt 4+1") == nil)
        #expect(Calculator.evaluate("sqrt(") == nil)
        #expect(Calculator.evaluate("e-mail") == nil)
    }
}
