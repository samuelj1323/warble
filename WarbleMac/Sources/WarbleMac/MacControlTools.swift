import Foundation

/// Native Mac-control tools dispatched by the on-device agent router, porting
/// `server/tools.py`'s behavior. Kept narrow — no arbitrary shell execution,
/// since arguments originate from a voice transcript (untrusted input).
final class MacControlTools {
    struct ProcessResult {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    typealias ProcessRunner = (_ executable: String, _ arguments: [String]) -> ProcessResult

    private let runProcess: ProcessRunner

    init(runProcess: ProcessRunner? = nil) {
        self.runProcess = runProcess ?? Self.realProcessRunner
    }

    private static func realProcessRunner(executable: String, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, standardOutput: "", standardError: "\(error)")
        }
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, standardOutput: stdout, standardError: stderr)
    }

    private func trimmedError(_ result: ProcessResult) -> String {
        result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func openApp(name: String) -> String {
        let result = runProcess("/usr/bin/open", ["-a", name])
        guard result.exitCode == 0 else {
            return "failed to open \(name): \(trimmedError(result))"
        }
        return "opened \(name)"
    }

    func openURL(_ url: String) -> String {
        let fullURL = (url.hasPrefix("http://") || url.hasPrefix("https://")) ? url : "https://\(url)"
        let result = runProcess("/usr/bin/open", [fullURL])
        guard result.exitCode == 0 else {
            return "failed to open \(fullURL): \(trimmedError(result))"
        }
        return "opened \(fullURL)"
    }

    private func osascript(_ script: String) -> ProcessResult {
        runProcess("/usr/bin/osascript", ["-e", script])
    }

    func setVolume(level: Int) -> String {
        let clamped = max(0, min(100, level))
        let result = osascript("set volume output volume \(clamped)")
        guard result.exitCode == 0 else {
            return "failed to set volume: \(trimmedError(result))"
        }
        return "volume set to \(clamped)"
    }

    func setMute(muted: Bool) -> String {
        let result = osascript("set volume output muted \(muted ? "true" : "false")")
        guard result.exitCode == 0 else {
            return "failed to \(muted ? "mute" : "unmute"): \(trimmedError(result))"
        }
        return muted ? "muted" : "unmuted"
    }

    func lockScreen() -> String {
        let result = osascript("tell application \"System Events\" to keystroke \"q\" using {control down, command down}")
        guard result.exitCode == 0 else {
            return "failed to lock screen: \(trimmedError(result))"
        }
        return "locked screen"
    }

    func sleepDisplay() -> String {
        let result = runProcess("/usr/bin/pmset", ["displaysleepnow"])
        guard result.exitCode == 0 else {
            return "failed to sleep display: \(trimmedError(result))"
        }
        return "display sleeping"
    }

    func takeScreenshot() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let path = NSHomeDirectory() + "/Desktop/warble-screenshot-\(formatter.string(from: Date())).png"
        let result = runProcess("/usr/sbin/screencapture", ["-x", path])
        guard result.exitCode == 0 else {
            return "failed to take screenshot: \(trimmedError(result))"
        }
        return "screenshot saved to \(path)"
    }

    private static let mediaVerbs = ["play_pause": "playpause", "next": "next track", "previous": "previous track"]
    private static let mediaPlayers = ["Spotify", "Music"]

    func mediaControl(action: String) -> String {
        guard let verb = Self.mediaVerbs[action] else {
            return "unknown media action: \(action)"
        }

        for player in Self.mediaPlayers {
            let running = osascript("application \"\(player)\" is running")
            guard running.exitCode == 0, running.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                continue
            }
            let result = osascript("tell application \"\(player)\" to \(verb)")
            guard result.exitCode == 0 else {
                return "failed to \(action) on \(player): \(trimmedError(result))"
            }
            return "\(action) on \(player)"
        }

        return "no supported media player (Spotify/Music) is running"
    }
}
