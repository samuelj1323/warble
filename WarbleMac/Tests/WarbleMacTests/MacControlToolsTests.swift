import XCTest
@testable import WarbleMac

final class MacControlToolsTests: XCTestCase {
    func testOpenAppRunsOpenWithAppNameAndReturnsSuccessMessage() {
        var capturedExecutable: String?
        var capturedArguments: [String]?
        let tools = MacControlTools(runProcess: { executable, arguments in
            capturedExecutable = executable
            capturedArguments = arguments
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })

        let result = tools.openApp(name: "Safari")

        XCTAssertEqual(capturedExecutable, "/usr/bin/open")
        XCTAssertEqual(capturedArguments, ["-a", "Safari"])
        XCTAssertEqual(result, "opened Safari")
    }

    func testOpenAppReturnsFailureMessageOnNonZeroExit() {
        let tools = MacControlTools(runProcess: { _, _ in
            MacControlTools.ProcessResult(exitCode: 1, standardOutput: "", standardError: "no such app")
        })

        let result = tools.openApp(name: "NotAnApp")

        XCTAssertEqual(result, "failed to open NotAnApp: no such app")
    }

    func testOpenURLAddsHTTPSSchemeWhenMissing() {
        var capturedArguments: [String]?
        let tools = MacControlTools(runProcess: { _, arguments in
            capturedArguments = arguments
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })

        let result = tools.openURL("example.com")

        XCTAssertEqual(capturedArguments, ["https://example.com"])
        XCTAssertEqual(result, "opened https://example.com")
    }

    func testOpenURLLeavesExistingSchemeAlone() {
        var capturedArguments: [String]?
        let tools = MacControlTools(runProcess: { _, arguments in
            capturedArguments = arguments
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })

        _ = tools.openURL("http://example.com")

        XCTAssertEqual(capturedArguments, ["http://example.com"])
    }

    func testSetVolumeClampsToValidRangeAndUsesOsascript() {
        var capturedExecutable: String?
        var capturedArguments: [String]?
        let tools = MacControlTools(runProcess: { executable, arguments in
            capturedExecutable = executable
            capturedArguments = arguments
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })

        let result = tools.setVolume(level: 150)

        XCTAssertEqual(capturedExecutable, "/usr/bin/osascript")
        XCTAssertEqual(capturedArguments, ["-e", "set volume output volume 100"])
        XCTAssertEqual(result, "volume set to 100")
    }

    func testSetMuteTrue() {
        var capturedArguments: [String]?
        let tools = MacControlTools(runProcess: { _, arguments in
            capturedArguments = arguments
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })

        let result = tools.setMute(muted: true)

        XCTAssertEqual(capturedArguments, ["-e", "set volume output muted true"])
        XCTAssertEqual(result, "muted")
    }

    func testLockScreenRunsExpectedKeystroke() {
        var capturedArguments: [String]?
        let tools = MacControlTools(runProcess: { _, arguments in
            capturedArguments = arguments
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })

        let result = tools.lockScreen()

        XCTAssertEqual(
            capturedArguments,
            ["-e", "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"]
        )
        XCTAssertEqual(result, "locked screen")
    }

    func testSleepDisplayRunsPmset() {
        var capturedExecutable: String?
        var capturedArguments: [String]?
        let tools = MacControlTools(runProcess: { executable, arguments in
            capturedExecutable = executable
            capturedArguments = arguments
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })

        let result = tools.sleepDisplay()

        XCTAssertEqual(capturedExecutable, "/usr/bin/pmset")
        XCTAssertEqual(capturedArguments, ["displaysleepnow"])
        XCTAssertEqual(result, "display sleeping")
    }

    func testTakeScreenshotRunsScreencaptureAndReturnsPathMessage() {
        var capturedExecutable: String?
        var capturedArguments: [String]?
        let tools = MacControlTools(runProcess: { executable, arguments in
            capturedExecutable = executable
            capturedArguments = arguments
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })

        let result = tools.takeScreenshot()

        XCTAssertEqual(capturedExecutable, "/usr/sbin/screencapture")
        XCTAssertEqual(capturedArguments?.first, "-x")
        XCTAssertTrue(result.hasPrefix("screenshot saved to "))
    }

    func testMediaControlDispatchesToRunningSpotify() {
        var runningCheckedApps: [String] = []
        let tools = MacControlTools(runProcess: { _, arguments in
            let script = arguments.last ?? ""
            if script.contains("is running") {
                let app = script.contains("Spotify") ? "Spotify" : "Music"
                runningCheckedApps.append(app)
                let isRunning = app == "Spotify"
                return MacControlTools.ProcessResult(exitCode: 0, standardOutput: isRunning ? "true" : "false", standardError: "")
            }
            return MacControlTools.ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        })

        let result = tools.mediaControl(action: "play_pause")

        XCTAssertEqual(runningCheckedApps, ["Spotify"])
        XCTAssertEqual(result, "play_pause on Spotify")
    }

    func testMediaControlReturnsMessageWhenNoPlayerRunning() {
        let tools = MacControlTools(runProcess: { _, _ in
            MacControlTools.ProcessResult(exitCode: 0, standardOutput: "false", standardError: "")
        })

        let result = tools.mediaControl(action: "next")

        XCTAssertEqual(result, "no supported media player (Spotify/Music) is running")
    }
}
