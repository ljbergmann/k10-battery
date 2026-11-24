import AppKit
import ServiceManagement
import UserNotifications
import os

private let log = Logger(subsystem: "local.k10battery", category: "battery")

@MainActor
final class BatteryModel: ObservableObject {
    @Published private(set) var percent: Int?
    @Published private(set) var firmwarePercent: Int?
    @Published private(set) var millivolts: Int?
    @Published private(set) var charging = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var connected = false
    @Published private(set) var hasAccess = HIDBatteryReader.hasAccess
    @Published private(set) var hoursLeft: Double?
    @Published private(set) var history: [BatterySample] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var showWhileAsleep: Bool {
        didSet { defaults.set(showWhileAsleep, forKey: "showWhileAsleep"); refreshPowerSource() }
    }

    static let lowThreshold = 15
    private let reader = HIDBatteryReader()
    private let powerSource = PowerSourcePublisher()
    private let store = BatteryHistory()
    private var recentMV: [Int] = []          // smoothed by median
    private var recentPct: [Int] = []
    private var warnedLow = false
    private var notifiedFull = false
    private let defaults = UserDefaults.standard
    /// Learned from past charges (real level after unplugging); 3 h until then.
    private var hoursPerFullCharge: Double {
        get { let v = defaults.double(forKey: "hoursPerFullCharge"); return v > 0 ? v : 3.0 }
        set { defaults.set(newValue, forKey: "hoursPerFullCharge") }
    }

    init() {
        showWhileAsleep = defaults.bool(forKey: "showWhileAsleep")
        if defaults.object(forKey: "percent") != nil {
            percent = defaults.integer(forKey: "percent")
            charging = defaults.bool(forKey: "charging")
            lastUpdate = defaults.object(forKey: "lastUpdate") as? Date
            if defaults.object(forKey: "millivolts") != nil { millivolts = defaults.integer(forKey: "millivolts") }
        }
        history = store.samples
        hoursLeft = (percent != nil && !charging) ? BatteryMath.hoursLeft(percent: percent!, history: history) : nil

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
        if showWhileAsleep { refreshPowerSource() }

        // Fresh reading after the Mac wakes up.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.requestReading() }
            }
        }

        // Pick up the Input Monitoring grant without a relaunch; refresh "x min ago".
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                if !self.hasAccess && HIDBatteryReader.hasAccess {
                    self.hasAccess = true
                    self.reader.start()
                }
                self.objectWillChange.send()
            }
        }
    }

    /// Ask the keyboard for a reading right now (menu opened, wake, Refresh).
    func requestReading() { reader.requestReading() }

    private func learnChargeRate(from start: BatteryMath.ChargeStart, reached level: Int) {
        let hours = Date().timeIntervalSince(start.date) / 3600
        let gained = Double(level - start.level)
        guard hours >= 0.5, gained >= 20, level < 95 else { return }   // a full battery hides the real time
        let measured = min(max(hours / (gained / 100), 1), 8)
        hoursPerFullCharge = (hoursPerFullCharge + measured) / 2
        log.notice("charge rate: \(String(format: "%.2f", measured)) h per full charge, now using \(String(format: "%.2f", self.hoursPerFullCharge))")
    }

    private func connectionChanged(_ c: Bool) {
        log.notice("keyboard \(c ? "connected" : "disconnected", privacy: .public)")
        connected = c
        refreshPowerSource()
        // A freshly connected keyboard needs a few seconds before its voltage is
        // settled; the firmware keeps the request pending until then.
        if c { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.requestReading() } }
    }

    private func apply(_ r: HIDBatteryReader.Reading) {
        if r.charging != charging { recentMV.removeAll(); recentPct.removeAll() }  // voltage jumps on plug/unplug
        func median(_ a: [Int]) -> Int { a.sorted()[a.count / 2] }

        recentPct.append(r.percent); if recentPct.count > 5 { recentPct.removeFirst() }
        firmwarePercent = median(recentPct)
        if let mv = r.millivolts {
            recentMV.append(mv); if recentMV.count > 5 { recentMV.removeFirst() }
            millivolts = median(recentMV)
        } else {
            millivolts = nil
        }
        // On battery: calibrated curve, from the voltage or (firmware v1.0)
        // from Keychron's percentage turned back into its voltage. Charging
        // voltage is inflated by the charger, so there we show the firmware's value.
        let mv = millivolts ?? BatteryMath.millivolts(keychronPercent: firmwarePercent!)
        var shown = BatteryMath.percent(millivolts: mv)
        if r.charging {
            // Time-based estimate; the firmware's value only if the plug-in level is unknown.
            shown = BatteryMath.chargeStart(history).map {
                BatteryMath.chargingLevel(from: $0, hoursPerFullCharge: hoursPerFullCharge)
            } ?? firmwarePercent!
        } else if let start = BatteryMath.chargeStart(history) {
            // Just unplugged: learn the charge rate from what the battery really got.
            learnChargeRate(from: start, reached: shown)
        } else if let prev = percent, !charging {
            // On battery: the level can't fall faster than the keyboard can use
            // power. After unplugging, the voltage sinks for ~30 min while the
            // cell settles; that's not charge being used.
            shown = BatteryMath.limitDrop(to: shown, from: prev, history: history)
        }

        percent = shown
        charging = r.charging
        lastUpdate = Date()
        connected = true
        defaults.set(shown, forKey: "percent")
        defaults.set(r.charging, forKey: "charging")
        defaults.set(lastUpdate, forKey: "lastUpdate")
        if let mv = millivolts { defaults.set(mv, forKey: "millivolts") } else { defaults.removeObject(forKey: "millivolts") }

        store.add(BatterySample(date: Date(), percent: shown, millivolts: mv, charging: r.charging))
        history = store.samples
        hoursLeft = r.charging ? nil : BatteryMath.hoursLeft(percent: shown, history: history)
        refreshPowerSource()

        if !charging && shown <= Self.lowThreshold && !warnedLow {
            warnedLow = true
            notify("low", "Keychron K10 battery low", "\(shown)% left - time to plug it in.")
        }
        if charging || shown > Self.lowThreshold + 5 { warnedLow = false }

        if charging && shown >= 100 && !notifiedFull {   // the firmware says 100 % long before it is
            notifiedFull = true
            notify("full", "Keychron K10 charged", "It should be fully charged now. You can unplug it.")
        }
        if !charging { notifiedFull = false }
    }

    private func refreshPowerSource() {
        guard let p = percent, connected || showWhileAsleep else { return powerSource.withdraw() }
        powerSource.publish(percent: p, charging: charging && connected, productID: reader.productID,
                            minutesToEmpty: hoursLeft.map { Int($0 * 60) })
    }

    private func notify(_ id: String, _ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
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

    var timeLeftText: String? {
        guard let h = hoursLeft, !charging else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = h >= 48 ? [.day, .hour] : [.hour, .minute]
        f.unitsStyle = .abbreviated; f.maximumUnitCount = 2
        return f.string(from: h * 3600).map { "≈ \($0) of use left" }
    }
}
