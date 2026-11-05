import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class BatteryModel: ObservableObject {
    @Published private(set) var percent: Int?
    @Published private(set) var charging = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var connected = false
    @Published private(set) var hasAccess = HIDBatteryReader.hasAccess
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    static let lowThreshold = 15
    private let reader = HIDBatteryReader()
    private let powerSource = PowerSourcePublisher()
    private var recent: [Int] = []          // raw readings, smoothed by median
    private var warnedLow = false
    private let defaults = UserDefaults.standard

    init() {
        if defaults.object(forKey: "percent") != nil {
            percent = defaults.integer(forKey: "percent")
            charging = defaults.bool(forKey: "charging")
            lastUpdate = defaults.object(forKey: "lastUpdate") as? Date
        }
        reader.onReading = { [weak self] r in MainActor.assumeIsolated { self?.apply(r) } }
        reader.onConnectionChange = { [weak self] c in MainActor.assumeIsolated { self?.connectionChanged(c) } }
        if !hasAccess { HIDBatteryReader.requestAccess() }
        // First launch from /Applications: turn on launch at login once (user can turn it off in the menu).
        if Bundle.main.bundlePath.hasPrefix("/Applications/") && !defaults.bool(forKey: "didAutoEnableLogin") {
            defaults.set(true, forKey: "didAutoEnableLogin")
            setLaunchAtLogin(true)
        }
        reader.start()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Pick up the Input Monitoring grant without needing a relaunch of the UI.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                if !self.hasAccess && HIDBatteryReader.hasAccess {
                    self.hasAccess = true
                    self.reader.start()
                }
                self.objectWillChange.send() // refresh "x min ago"
            }
        }
    }

    /// Show the keyboard in the system Batteries widget only while it's connected,
    /// starting from the last known value until a fresh reading arrives.
    private func connectionChanged(_ c: Bool) {
        connected = c
        if c, let p = percent { powerSource.publish(percent: p, charging: charging, productID: reader.productID) }
        if !c { powerSource.withdraw() }
    }

    private func apply(_ r: HIDBatteryReader.Reading) {
        if r.charging != charging { recent.removeAll() }   // voltage jumps on plug/unplug
        recent.append(r.percent)
        if recent.count > 5 { recent.removeFirst() }
        let smoothed = recent.sorted()[recent.count / 2]

        percent = smoothed
        charging = r.charging
        lastUpdate = Date()
        connected = true
        defaults.set(smoothed, forKey: "percent")
        defaults.set(r.charging, forKey: "charging")
        defaults.set(lastUpdate, forKey: "lastUpdate")
        powerSource.publish(percent: smoothed, charging: r.charging, productID: reader.productID)

        if !charging && smoothed <= Self.lowThreshold && !warnedLow {
            warnedLow = true
            notify("Keychron K10 battery low", "\(smoothed)% left - time to plug it in.")
        }
        if charging || smoothed > Self.lowThreshold + 5 { warnedLow = false }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "low", content: c, trigger: nil))
    }

    func openInputMonitoringSettings() {
        HIDBatteryReader.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("K10Battery: launch at login failed: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var symbolName: String {
        guard let p = percent else { return "keyboard" }
        if charging { return "battery.100percent.bolt" }
        switch p {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var ageText: String {
        guard let d = lastUpdate else { return "No reading yet" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return "Updated " + f.localizedString(for: d, relativeTo: Date())
    }
}
