import AppKit
import XCTest
@testable import WarbleMac

@MainActor
final class PasteServiceTests: XCTestCase {
    func testPasteWritesTextToPasteboard() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.warble.test.\(UUID().uuidString)"))
        var keystrokeSent = false
        let service = PasteService(
            pasteboard: pasteboard,
            sendPasteKeystroke: { keystrokeSent = true },
            frontmostAppName: { "TestApp" }
        )

        let appName = await service.paste(text: "hello world")

        XCTAssertEqual(pasteboard.string(forType: .string), "hello world")
        XCTAssertTrue(keystrokeSent)
        XCTAssertEqual(appName, "TestApp")
    }

    func testPasteWithEmptyTextDoesNothing() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.warble.test.\(UUID().uuidString)"))
        pasteboard.setString("preexisting", forType: .string)
        var keystrokeSent = false
        let service = PasteService(pasteboard: pasteboard, sendPasteKeystroke: { keystrokeSent = true })

        let appName = await service.paste(text: "")

        XCTAssertEqual(pasteboard.string(forType: .string), "preexisting")
        XCTAssertFalse(keystrokeSent)
        XCTAssertNil(appName)
    }

    func testPasteIntoRunningTargetActivatesItAndRefocuses() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.warble.test.\(UUID().uuidString)"))
        let target = NSRunningApplication.current
        var activated: NSRunningApplication?
        var launchCalled = false
        var reactivated = false
        let service = PasteService(
            pasteboard: pasteboard,
            sendPasteKeystroke: {},
            frontmostAppName: { "Focused" },
            activate: { activated = $0 },
            reactivateSelf: { reactivated = true },
            runningApp: { _ in target },
            launchApp: { _ in launchCalled = true; return nil }
        )

        let appName = await service.paste(text: "hi", target: .app(bundleID: "com.example.app", name: "Example"))

        XCTAssertEqual(pasteboard.string(forType: .string), "hi")
        XCTAssertIdentical(activated, target)
        XCTAssertFalse(launchCalled, "an already-running target should not be launched")
        XCTAssertTrue(reactivated, "Warble should reclaim focus after pasting into another app")
        XCTAssertEqual(appName, "Example")
    }

    func testPasteIntoNotRunningTargetLaunchesIt() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.warble.test.\(UUID().uuidString)"))
        let launched = NSRunningApplication.current
        var activated: NSRunningApplication?
        var launchedBundleID: String?
        let service = PasteService(
            pasteboard: pasteboard,
            sendPasteKeystroke: {},
            frontmostAppName: { "Focused" },
            activate: { activated = $0 },
            reactivateSelf: {},
            runningApp: { _ in nil },
            launchApp: { bundleID in launchedBundleID = bundleID; return launched }
        )

        let appName = await service.paste(text: "hi", target: .app(bundleID: "com.example.app", name: "Example"))

        XCTAssertEqual(launchedBundleID, "com.example.app")
        XCTAssertIdentical(activated, launched)
        XCTAssertEqual(appName, "Example")
    }

    func testPasteIntoUnresolvableTargetFallsBackToFocusedApp() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.warble.test.\(UUID().uuidString)"))
        var reactivated = false
        let service = PasteService(
            pasteboard: pasteboard,
            sendPasteKeystroke: {},
            frontmostAppName: { "Focused" },
            activate: { _ in },
            reactivateSelf: { reactivated = true },
            runningApp: { _ in nil },
            launchApp: { _ in nil }
        )

        let appName = await service.paste(text: "hi", target: .app(bundleID: "com.example.missing", name: "Missing"))

        XCTAssertEqual(pasteboard.string(forType: .string), "hi")
        XCTAssertFalse(reactivated, "no other app was activated, so no refocus is needed")
        XCTAssertEqual(appName, "Focused", "an unresolvable target reports the real focused destination")
    }
}
