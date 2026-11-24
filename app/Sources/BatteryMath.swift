import Foundation

enum BatteryMath {
    /// Voltage -> real charge, measured on a K10 Pro ISO RGB (backlight off)
    /// by `tools/calibrate.py`: the real charge at each voltage is the share of
    /// active typing time that was still left before the keyboard shut off.
    /// Above 3.84 V (not covered by that run) the generic Li-ion curve is used.
    /// Voltages are the firmware's load-compensated values.
    private static let curve: [(mv: Double, p: Double)] = [
        (3300, 0.0), (3330, 0.2), (3360, 1.2), (3390, 2.4), (3420, 3.2), (3450, 4.2),
        (3480, 5.1), (3510, 6.2), (3540, 7.7), (3570, 9.0), (3600, 11.2), (3630, 14.3),
        (3660, 20.3), (3690, 24.5), (3720, 29.2), (3750, 34.1), (3780, 43.9), (3810, 51.3),
        (3840, 62.7), (3860, 67.5), (3900, 74.2), (3950, 80.9), (4000, 86.3), (4050, 94.2),
        (4100, 100.0),
    ]

    /// Typing hours per 1 % from the calibration run (backlight off). Only a
    /// starting value; the learned rate replaces it after a few hours of use.
    static let priorHoursPerPercent = 0.86

    static func percent(millivolts mv: Int) -> Int {
        let v = Double(mv)
        if v <= curve.first!.mv { return 0 }
        if v >= curve.last!.mv { return 100 }
        for i in 1..<curve.count where v <= curve[i].mv {
            let a = curve[i - 1], b = curve[i]
            return Int((a.p + (v - a.mv) / (b.mv - a.mv) * (b.p - a.p)).rounded())
        }
        return 100
    }

    /// Inverse of Keychron's battery_get_percentage(): 4.10 V = 100 %,
    /// 3.50 V = 20 %, 3.30 V = 0 %, straight lines in between. Lets readings
    /// from firmware without voltage (v1.0) use the calibrated curve too.
    static func millivolts(keychronPercent p: Int) -> Int {
        let p = Double(min(max(p, 0), 100))
        return Int((p >= 20 ? 3500 + (p - 20) * 600 / 80 : 3300 + p * 200 / 20).rounded())
    }

    /// Gaps longer than this between samples count as "not in use".
    static let activeGap: TimeInterval = 15 * 60

    /// Discharge rate in percent per hour of *use* (least-squares slope over
    /// active time, so nights and weekends don't count) for the current
    /// on-battery stretch. nil until there are 3 active hours and 3 % of drop.
    static func dischargeRate(_ history: [BatterySample], now: Date = Date()) -> Double? {
        let lastCharge = history.lastIndex(where: { $0.charging })
        let stretch = Array(history[(lastCharge.map { $0 + 1 } ?? 0)...]
            .filter { now.timeIntervalSince($0.date) < 14 * 86400 })
        guard let first = stretch.first, let last = stretch.last,
              first.level - last.level >= 3 else { return nil }

        var xs: [Double] = [0], t = 0.0
        for (a, b) in zip(stretch, stretch.dropFirst()) {
            let g = b.date.timeIntervalSince(a.date)
            if g <= activeGap { t += g / 3600 }
            xs.append(t)
        }
        guard t >= 3 else { return nil }
        let ys = stretch.map { Double($0.level) }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        let sxy = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let slope = -sxy / sxx
        return slope > 0.01 ? slope : nil
    }

    /// While charging, the voltage is pushed up by the charger and says little
    /// about the real charge (the firmware reported 59 % 16 min after empty).
    /// So the level is estimated from time instead: level at plug-in plus
    /// elapsed time, at `hoursPerFullCharge` for 0 -> 100 %. Returns the
    /// plug-in point too, so the real level after unplugging can refine the rate.
    struct ChargeStart { let date: Date; let level: Int }

    static func chargeStart(_ history: [BatterySample]) -> ChargeStart? {
        guard let last = history.last, last.charging else { return nil }
        var i = history.count - 1
        while i > 0 && history[i - 1].charging { i -= 1 }
        // need the last on-battery reading shortly before plugging in
        guard i > 0, history[i].date.timeIntervalSince(history[i - 1].date) < 2 * 3600 else { return nil }
        return ChargeStart(date: history[i].date, level: history[i - 1].level)
    }

    static func chargingLevel(from start: ChargeStart, hoursPerFullCharge: Double, now: Date = Date()) -> Int {
        let h = now.timeIntervalSince(start.date) / 3600
        let p = Double(start.level) + h / hoursPerFullCharge * 100
        return p >= 100 ? 100 : min(99, Int(p.rounded()))
    }

    /// Caps a drop in the shown level at 3x the usage rate (learned from the
    /// raw voltage-based levels in the history, or the calibration prior),
    /// over the active time since the shown level last changed. On battery the
    /// level never rises, unless the voltage says so by more than 3 %.
    static func limitDrop(to new: Int, from prev: Int, history: [BatterySample], now: Date = Date()) -> Int {
        if new >= prev { return new - prev > 3 ? new : prev }
        // start of the tail of on-battery samples showing `prev`
        var i = history.count
        while i > 0, !history[i - 1].charging, history[i - 1].percent == prev { i -= 1 }
        guard i < history.count else { return prev }   // not in the history yet (5 min spacing): hold
        var hours = 0.0
        let times = history[i...].map(\.date) + [now]
        for (x, y) in zip(times, times.dropFirst()) { hours += min(y.timeIntervalSince(x), activeGap) / 3600 }
        let rate = max(dischargeRate(history, now: now) ?? 0, 1 / priorHoursPerPercent)
        return max(new, prev - Int(3 * rate * hours))
    }

    /// Hours of use left: learned rate, or the calibration prior until then.
    static func hoursLeft(percent: Int, history: [BatterySample]) -> Double {
        if let r = dischargeRate(history) { return Double(percent) / r }
        return Double(percent) * priorHoursPerPercent
    }
}

struct BatterySample: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    let percent: Int
    let millivolts: Int?
    let charging: Bool

    /// Calibrated level. Older samples stored Keychron's own percentage and
    /// no voltage; those are converted. While charging, the firmware's value.
    var level: Int {
        if charging { return percent }
        return BatteryMath.percent(millivolts: millivolts ?? BatteryMath.millivolts(keychronPercent: percent))
    }
}

/// Persistent reading history (Application Support/K10 Battery/history.json),
/// at most one sample per 5 minutes, kept for 30 days.
final class BatteryHistory {
    private(set) var samples: [BatterySample] = []
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("K10 Battery", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            samples = (try? dec.decode([BatterySample].self, from: data)) ?? []
        }
    }

    func add(_ s: BatterySample) {
        if let last = samples.last, s.date.timeIntervalSince(last.date) < 300, last.charging == s.charging {
            return                                  // at most one sample per 5 min
        }
        samples.append(s)
        samples.removeAll { s.date.timeIntervalSince($0.date) > 30 * 86400 }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(samples).write(to: url, options: .atomic)
    }
}
