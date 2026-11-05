import SwiftUI

@main
struct K10BatteryApp: App {
    @StateObject private var model = BatteryModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "keyboard")
                if let p = model.percent {
                    Image(systemName: model.symbolName)
                    Text("\(p)%")
                } else {
                    Text("–")
                }
            }
        }
        .menuBarExtraStyle(.window)
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
                    Text(model.connected ? "Connected" : "Not connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let p = model.percent {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(p)%").font(.system(size: 30, weight: .semibold, design: .rounded))
                    if model.charging { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
                    Spacer()
                }
                ProgressView(value: Double(p), total: 100)
                    .tint(p <= BatteryModel.lowThreshold && !model.charging ? .red : .green)
                Text(model.charging ? "Charging · \(model.ageText)" : model.ageText)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Waiting for the keyboard to report… type a few keys over Bluetooth.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.hasAccess {
                Divider()
                Text("Needs Input Monitoring permission to read the keyboard.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Input Monitoring Settings…") { model.openInputMonitoringSettings() }
            }

            Divider()
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                    set: { model.setLaunchAtLogin($0) }))
            Button("Quit K10 Battery") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 260)
    }
}
