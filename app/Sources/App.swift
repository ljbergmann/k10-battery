import Charts
import SwiftUI

@main
struct K10BatteryApp: App {
    @StateObject private var model = BatteryModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: MenuBarLabel(model: model).image)
                .accessibilityLabel(model.percent.map { "Keyboard battery \($0) percent" + (model.connected ? "" : ", not connected") }
                                    ?? "Keyboard battery unknown")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar label, rendered to a template image so it can be greyed out
/// while the keyboard is disconnected (SwiftUI drops opacity in menu bar labels,
/// but the alpha of a template image is kept and still follows light/dark mode).
@MainActor
struct MenuBarLabel {
    let model: BatteryModel

    var image: NSImage {
        let content = HStack(spacing: 3) {
            Image(systemName: "keyboard")
            if let p = model.percent {
                Image(systemName: model.symbolName)
                Text("\(p)%")
            } else {
                Text("–")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.black)
        .opacity(model.connected ? 1 : 0.35)
        .padding(.vertical, 1)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = renderer.nsImage ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)!
        img.isTemplate = true
        return img
    }
}

struct MenuContent: View {
    @ObservedObject var model: BatteryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keychron K10 Pro").font(.headline)
                    Text(model.connected ? "Connected" : "Not connected · showing last known level")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.requestReading()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Ask the keyboard for a fresh reading")
                .disabled(!model.connected)
            }

            if let p = model.percent {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(p)%").font(.system(size: 30, weight: .semibold, design: .rounded))
                    if model.charging { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
                    Spacer()
                    if let t = model.timeLeftText {
                        Text(t).font(.callout).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: Double(p), total: 100)
                    .tint(p <= BatteryModel.lowThreshold && !model.charging ? .red : .green)
                Text(detailText).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Waiting for the keyboard to report… type a few keys over Bluetooth.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.history.count >= 2 {
                HistoryChart(samples: model.history)
            }

            if !model.hasAccess {
                Divider()
                Text("Needs Input Monitoring permission to read the keyboard.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Input Monitoring Settings…") { model.openInputMonitoringSettings() }
            }

            Divider()
            Toggle("Show in Batteries widget while asleep", isOn: $model.showWhileAsleep)
                .help("Keep the last known level in the system Batteries widget when the keyboard sleeps or disconnects.")
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                    set: { model.setLaunchAtLogin($0) }))
            Button("Quit K10 Battery") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { model.requestReading() }
    }

    private var detailText: String {
        var parts: [String] = []
        if model.charging { parts.append("Charging") }
        if let mv = model.millivolts { parts.append(String(format: "%.2f V", Double(mv) / 1000)) }
        if let fw = model.firmwarePercent, let p = model.percent, abs(fw - p) >= 5 {
            parts.append("Keychron: \(fw)%")
        }
        parts.append(model.ageText)
        return parts.joined(separator: " · ")
    }
}

/// Battery level over the last 7 days.
struct HistoryChart: View {
    let samples: [BatterySample]

    var body: some View {
        let from = Date().addingTimeInterval(-7 * 86400)
        let recent = samples.filter { $0.date >= from }
        Chart(recent) { s in
            LineMark(x: .value("Time", s.date), y: .value("Battery", s.percent))
                .interpolationMethod(.monotone)
                .foregroundStyle(.green)
            if s.charging {
                PointMark(x: .value("Time", s.date), y: .value("Battery", s.percent))
                    .symbolSize(10)
                    .foregroundStyle(.yellow)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { AxisGridLine(); AxisValueLabel() } }
        .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
        .frame(height: 70)
        .accessibilityLabel("Battery history, last 7 days")
    }
}
