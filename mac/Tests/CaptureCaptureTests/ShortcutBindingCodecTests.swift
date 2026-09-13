import XCTest
import CaptureCore
@testable import CaptureCapture

final class ShortcutBindingCodecTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let bindings: [ShortcutAction: ShortcutBinding] = [
            .captureArea: ShortcutBinding(keyCode: CarbonKeyCode.ansi4, modifiers: [.shift, .command], displayString: "⇧⌘4"),
            .captureWindow: ShortcutBinding(keyCode: CarbonKeyCode.ansi5, modifiers: [.shift, .command, .control]),
            .toggleInspectMode: ShortcutBinding(keyCode: 34, modifiers: [.option, .command])
        ]
        let data = try ShortcutBindingCodec.encode(bindings)
        let decoded = try ShortcutBindingCodec.decode(data)
        XCTAssertEqual(decoded, bindings)
    }

    func testEmptyBindingsRoundTrip() throws {
        let data = try ShortcutBindingCodec.encode([:])
        let decoded = try ShortcutBindingCodec.decode(data)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testDecodeSkipsUnknownActionKeysForForwardCompatibility() throws {
        // Simulates a UserDefaults payload written by a future app version
        // with an action this build doesn't know about. `modifiers` mirrors
        // `ShortcutModifiers`' synthesized Codable shape (a nested
        // `{"rawValue": ...}` object, since it's a plain OptionSet struct
        // with no custom encode/decode) rather than a bare integer.
        let json = """
        {
            "captureArea": {"keyCode": 21, "modifiers": {"rawValue": 9}},
            "someFutureAction": {"keyCode": 1, "modifiers": {"rawValue": 0}}
        }
        """
        let decoded = try ShortcutBindingCodec.decode(Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[.captureArea]?.keyCode, 21)
    }

    func testPersistsThroughUserDefaultsViaGlobalShortcutManager() {
        let suiteName = "com.capture.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create ephemeral UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let binding = ShortcutBinding(keyCode: CarbonKeyCode.ansi4, modifiers: [.shift, .command])

        do {
            let manager = GlobalShortcutManager(userDefaults: defaults, defaultsKey: "test.bindings")
            manager.setBinding(binding, for: .captureArea)
        }

        // A freshly constructed manager reading the same suite/key should
        // observe the persisted binding without any monitor ever starting.
        let reloaded = GlobalShortcutManager(userDefaults: defaults, defaultsKey: "test.bindings")
        XCTAssertEqual(reloaded.binding(for: .captureArea), binding)
    }

    func testRemovingABindingPersistsTheRemoval() {
        let suiteName = "com.capture.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create ephemeral UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = GlobalShortcutManager(userDefaults: defaults, defaultsKey: "test.bindings")
        manager.setBinding(ShortcutBinding(keyCode: CarbonKeyCode.ansi3, modifiers: [.shift, .command]), for: .captureFullScreen)
        manager.removeBinding(for: .captureFullScreen)

        let reloaded = GlobalShortcutManager(userDefaults: defaults, defaultsKey: "test.bindings")
        XCTAssertNil(reloaded.binding(for: .captureFullScreen))
    }
}

final class ShortcutMatcherTests: XCTestCase {
    func testMatchesExactKeyCodeAndModifiers() {
        let bindings: [ShortcutAction: ShortcutBinding] = [
            .captureArea: ShortcutBinding(keyCode: CarbonKeyCode.ansi4, modifiers: [.shift, .command])
        ]
        let event = ShortcutKeyEvent(keyCode: CarbonKeyCode.ansi4, modifiers: [.shift, .command])
        XCTAssertEqual(ShortcutMatcher.action(for: event, in: bindings), .captureArea)
    }

    func testDoesNotMatchOnPartialModifierOverlap() {
        let bindings: [ShortcutAction: ShortcutBinding] = [
            .captureArea: ShortcutBinding(keyCode: CarbonKeyCode.ansi4, modifiers: [.shift, .command])
        ]
        // Same key, but with an extra modifier held (Control) — must not match.
        let event = ShortcutKeyEvent(keyCode: CarbonKeyCode.ansi4, modifiers: [.shift, .command, .control])
        XCTAssertNil(ShortcutMatcher.action(for: event, in: bindings))
    }

    func testDoesNotMatchWrongKeyCode() {
        let bindings: [ShortcutAction: ShortcutBinding] = [
            .captureArea: ShortcutBinding(keyCode: CarbonKeyCode.ansi4, modifiers: [.shift, .command])
        ]
        let event = ShortcutKeyEvent(keyCode: CarbonKeyCode.ansi3, modifiers: [.shift, .command])
        XCTAssertNil(ShortcutMatcher.action(for: event, in: bindings))
    }

    func testNoBindingsNeverMatches() {
        let event = ShortcutKeyEvent(keyCode: CarbonKeyCode.ansi4, modifiers: [.shift, .command])
        XCTAssertNil(ShortcutMatcher.action(for: event, in: [:]))
    }
}

final class SystemShortcutsTests: XCTestCase {
    func testMacOSBuiltInsDetectsShiftCommand4Conflict() {
        let registry = SystemShortcuts.macOSBuiltIns()
        let detector = ShortcutConflictDetector()
        let binding = ShortcutBinding(keyCode: CarbonKeyCode.ansi4, modifiers: [.shift, .command])
        let result = detector.conflicts(assigning: binding, to: .captureArea, existing: [:], systemShortcuts: registry)
        guard case .systemShortcut(let description) = result else { return XCTFail("expected a system shortcut conflict") }
        XCTAssertTrue(description.contains("Selected Portion"), "unexpected description: \(description)")
    }

    func testMacOSBuiltInsDoesNotFlagAnUnrelatedBinding() {
        let registry = SystemShortcuts.macOSBuiltIns()
        let detector = ShortcutConflictDetector()
        let binding = ShortcutBinding(keyCode: 1, modifiers: [.control, .option])
        let result = detector.conflicts(assigning: binding, to: .captureArea, existing: [:], systemShortcuts: registry)
        XCTAssertNil(result)
    }
}
