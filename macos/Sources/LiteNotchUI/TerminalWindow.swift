import Foundation

/// Brings forward the terminal window and tab a Claude Code session runs
/// in, rather than whichever window of that terminal happens to be on top.
///
/// The `litenotch` CLI reports the session's terminal device (`ttys003`).
/// Terminal and iTerm2 can be asked, through AppleScript, which tab is on a
/// device; other terminals have no such interface, and for those only the
/// app is activated.
///
/// The script text is fixed. The device name is checked (`validTTY`) and
/// handed to `osascript` as an argument, never put into the script. macOS
/// asks the user once whether LiteNotch may control the terminal; until
/// they allow it, a click activates the app as before.
public enum TerminalWindow {
    /// A macOS pseudo-terminal name: `ttys` and one to four digits.
    public static func validTTY(_ s: String) -> Bool {
        guard s.hasPrefix("ttys") else { return false }
        let digits = s.dropFirst(4)
        return (1...4).contains(digits.count) && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The script for a terminal app, or nil when it cannot be asked.
    /// Each prints `ok` when it found and raised the tab, `none` otherwise.
    public static func script(bundleId: String) -> String? {
        switch bundleId {
        case "com.apple.Terminal": return terminalScript
        case "com.googlecode.iterm2": return iTermScript
        default: return nil
        }
    }

    /// What `osascript` is started with.
    public static func arguments(script: String, tty: String) -> [String] {
        ["-e", script, "/dev/" + tty]
    }

    static let terminalScript = """
    on run argv
        set target to item 1 of argv
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is target then
                        if miniaturized of w then set miniaturized of w to false
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "none"
    end run
    """

    static let iTermScript = """
    on run argv
        set target to item 1 of argv
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is target then
                            tell w to select
                            tell t to select
                            tell s to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "none"
    end run
    """

    /// How long the script may take before the app is activated anyway.
    /// The script keeps running after that (the first time, macOS shows its
    /// permission question and waits for the answer).
    static let patience: TimeInterval = 1.0
    static let giveUp: TimeInterval = 120

    /// Starts the script. Returns false when this terminal cannot be asked
    /// (the caller then activates the app itself). Otherwise `fallback` runs
    /// on the main queue if the tab was not raised, at most once.
    @discardableResult
    public static func focus(bundleId: String, tty: String, fallback: @escaping () -> Void) -> Bool {
        guard validTTY(tty), let script = script(bundleId: bundleId) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments(script: script, tty: tty)
        process.environment = [:]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let once = Once()
        process.terminationHandler = { p in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let found = p.terminationStatus == 0
                && String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
            // Either this result or the wait below decides, whichever is first.
            if once.claim(), !found { DispatchQueue.main.async(execute: fallback) }
        }
        do {
            try process.run()
        } catch {
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) {
            if once.claim() { fallback() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + giveUp) {
            if process.isRunning { process.terminate() }
        }
        return true
    }
}

/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
