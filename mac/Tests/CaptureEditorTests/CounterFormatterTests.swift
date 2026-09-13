import CaptureCore
@testable import CaptureEditor
import XCTest

final class CounterFormatterTests: XCTestCase {
    // MARK: - label(format:...)

    func testNumericLabel() {
        XCTAssertEqual(CounterFormatter.label(format: .numeric, startNumber: 1, zeroBasedIndex: 0, customLabels: nil), "1")
        XCTAssertEqual(CounterFormatter.label(format: .numeric, startNumber: 5, zeroBasedIndex: 2, customLabels: nil), "7")
    }

    func testAlphaUpperLabelWrapsPastZ() {
        XCTAssertEqual(CounterFormatter.label(format: .alphaUpper, startNumber: 1, zeroBasedIndex: 0, customLabels: nil), "A")
        XCTAssertEqual(CounterFormatter.label(format: .alphaUpper, startNumber: 1, zeroBasedIndex: 25, customLabels: nil), "Z")
        // Bijective base-26: the 27th value is "AA", not "A0"/"BA".
        XCTAssertEqual(CounterFormatter.label(format: .alphaUpper, startNumber: 1, zeroBasedIndex: 26, customLabels: nil), "AA")
        XCTAssertEqual(CounterFormatter.label(format: .alphaUpper, startNumber: 1, zeroBasedIndex: 27, customLabels: nil), "AB")
    }

    func testAlphaLowerLabel() {
        XCTAssertEqual(CounterFormatter.label(format: .alphaLower, startNumber: 1, zeroBasedIndex: 0, customLabels: nil), "a")
        XCTAssertEqual(CounterFormatter.label(format: .alphaLower, startNumber: 1, zeroBasedIndex: 1, customLabels: nil), "b")
    }

    func testRomanNumeralLabel() {
        XCTAssertEqual(CounterFormatter.label(format: .roman, startNumber: 1, zeroBasedIndex: 0, customLabels: nil), "I")
        XCTAssertEqual(CounterFormatter.label(format: .roman, startNumber: 1, zeroBasedIndex: 3, customLabels: nil), "IV")
        XCTAssertEqual(CounterFormatter.label(format: .roman, startNumber: 1, zeroBasedIndex: 8, customLabels: nil), "IX")
        XCTAssertEqual(CounterFormatter.label(format: .roman, startNumber: 1, zeroBasedIndex: 48, customLabels: nil), "XLIX") // 49
    }

    func testRomanNumeralOutOfRangeFallsBackToNumeric() {
        // startNumber + index == 4000, outside the conventional Roman range.
        XCTAssertEqual(CounterFormatter.label(format: .roman, startNumber: 4000, zeroBasedIndex: 0, customLabels: nil), "4000")
    }

    func testCustomLabels() {
        let labels = ["Alpha", "Beta", "Gamma"]
        XCTAssertEqual(CounterFormatter.label(format: .custom, startNumber: 1, zeroBasedIndex: 0, customLabels: labels), "Alpha")
        XCTAssertEqual(CounterFormatter.label(format: .custom, startNumber: 1, zeroBasedIndex: 2, customLabels: labels), "Gamma")
    }

    func testCustomLabelsFallBackToNumericWhenListRunsOut() {
        let labels = ["Only One"]
        XCTAssertEqual(CounterFormatter.label(format: .custom, startNumber: 1, zeroBasedIndex: 1, customLabels: labels), "2")
    }

    func testNegativeIndexProducesEmptyLabel() {
        XCTAssertEqual(CounterFormatter.label(format: .numeric, startNumber: 1, zeroBasedIndex: -1, customLabels: nil), "")
    }

    // MARK: - renumber(_:)

    private func makeCounter(zIndex: Int, sequenceId: String? = nil, resolvedIndex: Int? = nil) -> Annotation {
        var typeDataDict: [String: JSONValue] = [:]
        if let sequenceId { typeDataDict[AnnotationStyleKeys.counterSequenceId] = .string(sequenceId) }
        if let resolvedIndex { typeDataDict[AnnotationStyleKeys.counterResolvedIndex] = .number(Double(resolvedIndex)) }
        return Annotation(
            type: .counter,
            frame: CaptureRect(x: 0, y: 0, width: 24, height: 24),
            zIndex: zIndex,
            typeData: typeDataDict.isEmpty ? nil : .object(typeDataDict)
        )
    }

    private func resolvedIndex(_ annotation: Annotation) -> Int? {
        StyleReader(annotation).typeData?[AnnotationStyleKeys.counterResolvedIndex]?.doubleValue.map { Int($0) }
    }

    func testRenumberAssignsSequentialIndicesInZIndexOrder() {
        let counters = [makeCounter(zIndex: 2), makeCounter(zIndex: 0), makeCounter(zIndex: 1)]
        let renumbered = CounterFormatter.renumber(counters)
        let byZIndex = renumbered.sorted { $0.zIndex < $1.zIndex }
        XCTAssertEqual(byZIndex.map(resolvedIndex), [0, 1, 2])
    }

    func testRenumberAfterDeletionClosesTheGap() {
        // Simulates deleting the counter at zIndex 1 out of an original
        // 0/1/2 sequence — the "auto-renumber after insert/delete"
        // requirement: remaining counters become 0/1, not 0/2.
        let remaining = [makeCounter(zIndex: 0, resolvedIndex: 0), makeCounter(zIndex: 2, resolvedIndex: 2)]
        let renumbered = CounterFormatter.renumber(remaining).sorted { $0.zIndex < $1.zIndex }
        XCTAssertEqual(renumbered.map(resolvedIndex), [0, 1])
    }

    func testRenumberKeepsSequencesIndependent() {
        let sequenceA = [makeCounter(zIndex: 0, sequenceId: "A"), makeCounter(zIndex: 2, sequenceId: "A")]
        let sequenceB = [makeCounter(zIndex: 1, sequenceId: "B")]
        let renumbered = CounterFormatter.renumber(sequenceA + sequenceB)

        let aResults = renumbered.filter { StyleReader($0).typeDataString(AnnotationStyleKeys.counterSequenceId) == "A" }
            .sorted { $0.zIndex < $1.zIndex }
        let bResults = renumbered.filter { StyleReader($0).typeDataString(AnnotationStyleKeys.counterSequenceId) == "B" }

        XCTAssertEqual(aResults.map(resolvedIndex), [0, 1])
        XCTAssertEqual(bResults.map(resolvedIndex), [0])
    }

    func testRenumberLeavesNonCounterAnnotationsUntouched() {
        let arrow = Annotation(type: .arrow, frame: .zero, zIndex: 0)
        let renumbered = CounterFormatter.renumber([arrow])
        XCTAssertEqual(renumbered, [arrow])
    }

    func testRenumberIsNoOpWhenAlreadyCorrect() {
        let counters = [makeCounter(zIndex: 0, resolvedIndex: 0), makeCounter(zIndex: 1, resolvedIndex: 1)]
        let renumbered = CounterFormatter.renumber(counters)
        XCTAssertEqual(renumbered, counters)
    }

    // MARK: - Roman numeral internals (exercised indirectly above, spot-checked directly here)

    func testRomanNumeralBoundaries() {
        XCTAssertNil(CounterFormatter.romanNumeral(0))
        XCTAssertNil(CounterFormatter.romanNumeral(4000))
        XCTAssertEqual(CounterFormatter.romanNumeral(3999), "MMMCMXCIX")
        XCTAssertEqual(CounterFormatter.romanNumeral(1994), "MCMXCIV")
    }
}
