import Foundation

enum BatteryMath {
    /// Typical resting discharge curve of a 1-cell Li-ion/LiPo (V -> %).
    private static let curve: [(v: Double, p: Double)] = [
        (3.30, 0), (3.61, 5), (3.69, 10), (3.71, 15), (3.73, 20), (3.75, 25),
        (3.77, 30), (3.79, 35), (3.80, 40), (3.82, 45), (3.84, 50), (3.85, 55),
        (3.87, 60), (3.91, 65), (3.95, 70), (3.98, 75), (4.02, 80), (4.08, 85),
        (4.11, 90), (4.15, 95), (4.20, 100),
    ]

    /// Percent from the firmware's (load-compensated) voltage.
    /// Keychron's firmware treats 4.10 V as full and 3.30 V as shutdown, and
    /// interpolates linearly in two segments. Here the standard curve shape is
    /// mapped onto that same 3.30-4.10 V window, so the end points agree with
    /// Fn+B but the middle follows the real (non-linear) cell behaviour.
    static func percent(millivolts mv: Int) -> Int {
        let full = 4.10, empty = 3.30
        // map firmware voltage into the curve's 3.30-4.20 V domain
        let v = 3.30 + (Double(mv) / 1000 - empty) * (4.20 - 3.30) / (full - empty)
        if v <= curve.first!.v { return 0 }
        if v >= curve.last!.v { return 100 }
        for i in 1..<curve.count where v <= curve[i].v {
            let a = curve[i - 1], b = curve[i]
            return Int((a.p + (v - a.v) / (b.v - a.v) * (b.p - a.p)).rounded())
        }
        return 100
    }

    /// Discharge rate in percent per hour from the current on-battery stretch
    /// (least-squares slope). nil until there's enough data: at least 3 hours
    /// and 3 points of drop since the last time it was charging.
    static func dischargeRate(_ history: [BatterySample], now: Date = Date()) -> Double? {
        let lastCharge = history.lastIndex(where: { $0.charging })
        let stretch = history[(lastCharge.map { $0 + 1 } ?? 0)...]
            .filter { now.timeIntervalSince($0.date) < 14 * 86400 }
        guard let first = stretch.first, let last = stretch.last,
              last.date.timeIntervalSince(first.date) >= 3 * 3600,
              first.percent - last.percent >= 3 else { return nil }

        let xs = stretch.map { $0.date.timeIntervalSince(first.date) / 3600 }
        let ys = stretch.map { Double($0.percent) }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        let sxy = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let slope = -sxy / sxx
        return slope > 0.01 ? slope : nil
    }
}

struct BatterySample: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    let percent: Int
    let millivolts: Int?
    let charging: Bool
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
