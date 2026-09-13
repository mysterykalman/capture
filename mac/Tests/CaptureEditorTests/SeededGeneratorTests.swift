@testable import CaptureEditor
import CoreGraphics
import XCTest

final class SeededGeneratorTests: XCTestCase {
    func testSameSeedProducesSameSequence() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        let sequenceA = (0..<10).map { _ in a.next() }
        let sequenceB = (0..<10).map { _ in b.next() }
        XCTAssertEqual(sequenceA, sequenceB)
    }

    func testDifferentSeedsProduceDifferentSequences() {
        var a = SeededGenerator(seed: 1)
        var b = SeededGenerator(seed: 2)
        let sequenceA = (0..<5).map { _ in a.next() }
        let sequenceB = (0..<5).map { _ in b.next() }
        XCTAssertNotEqual(sequenceA, sequenceB)
    }

    func testZeroSeedDoesNotCrashOrDegenerate() {
        var generator = SeededGenerator(seed: 0)
        let values = (0..<20).map { _ in generator.next() }
        // Sanity check it isn't just emitting the same value repeatedly.
        XCTAssertGreaterThan(Set(values).count, 1)
    }

    func testHandDrawnJitterIsReproducibleForTheSameSeed() {
        let a = HandDrawnPath.jittered(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), seed: 7)
        let b = HandDrawnPath.jittered(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), seed: 7)
        XCTAssertEqual(a.count, b.count)
        for (p1, p2) in zip(a, b) {
            XCTAssertEqual(p1.x, p2.x, accuracy: 0.0001)
            XCTAssertEqual(p1.y, p2.y, accuracy: 0.0001)
        }
    }

    func testHandDrawnJitterEndpointsAreUnperturbed() {
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 110, y: 20)
        let points = HandDrawnPath.jittered(from: start, to: end, seed: 99, amplitude: 5, subdivisions: 8)
        XCTAssertEqual(points.first?.x, start.x)
        XCTAssertEqual(points.first?.y, start.y)
        XCTAssertEqual(points.last?.x, end.x)
        XCTAssertEqual(points.last?.y, end.y)
    }

    func testHandDrawnJitterWithZeroAmplitudeStaysOnTheLine() {
        let points = HandDrawnPath.jittered(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), seed: 3, amplitude: 0, subdivisions: 6)
        for point in points {
            XCTAssertEqual(point.y, 0, accuracy: 0.0001)
        }
    }
}
