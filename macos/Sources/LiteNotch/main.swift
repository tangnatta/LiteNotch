import AppKit
import CLiteNotch
import LiteNotchUI

/// Sends shell commands to the Rust core.
final class RustBridge: CoreBridge {
    func send(_ commandJSON: String) {
        _ = commandJSON.withCString { ln_send($0) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let bridge = RustBridge()
    private lazy var model = AppModel(bridge: bridge)
    private lazy var panel = NotchPanelController(model: model)
    private lazy var systemNotifications = SystemNotificationObserver(model: model)
    private var started = false
    private var dstWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard startCore() else {
            // Another LiteNotch owns the socket, or the data directory is unusable.
            NSApp.terminate(nil)
            return
        }
        started = true
        sendUTCOffset()
        // The offset also changes with daylight saving, which posts no
        // notification, so it is re-read on a new day and after waking too.
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sendUTCOffset()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.sendUTCOffset() }
        panel.show()
        systemNotifications.start()
        quitCleanlyOnSignals()
    }

    /// `kill` and Ctrl-C go through the normal quit path, so state is saved
    /// and keep-awake is released just as with the Quit button.
    private func quitCleanlyOnSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard started else { return }
        systemNotifications.stop()
        ln_stop()
    }

    private func startCore() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        var config: [String: String] = [
            "home": NSHomeDirectory(),
            "cli_path": Self.cliPath(),
            // System-wide now playing is read by the core through this helper.
            "nowplaying_lib": Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/libnowplaying.dylib").path,
        ]
        // Development and benchmarking: keep state away from the real app's.
        if let dataDir = environment["LITENOTCH_DATA_DIR"], !dataDir.isEmpty {
            config["data_dir"] = dataDir
        }
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else { return false }
        let context = Unmanaged.passUnretained(model).toOpaque()
        return json.withCString { ln_start($0, viewCallback, context) }
    }

    /// The CLI ships inside the bundle; hooks are registered with this path.
    private static func cliPath() -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/litenotch").path
    }

    private func sendUTCOffset() {
        NSTimeZone.resetSystemTimeZone()
        let zone = TimeZone.current
        model.send(.setUtcOffset(secs: zone.secondsFromGMT()))
        // One-shot, at the next daylight-saving change (if the zone has any).
        dstWork?.cancel()
        guard let next = zone.nextDaylightSavingTimeTransition else { return }
        let work = DispatchWorkItem { [weak self] in self?.sendUTCOffset() }
        dstWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, next.timeIntervalSinceNow + 1), execute: work)
    }
}

/// Called on the core's thread with the new view model. The model outlives
/// the core (it is released only after `ln_stop`), so the unretained
/// reference is valid here.
private let viewCallback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { json, context in
    guard let json, let context else { return }
    let model = Unmanaged<AppModel>.fromOpaque(context).takeUnretainedValue()
    model.receive(viewJSON: Data(bytes: json, count: strlen(json)))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
