import Foundation
import IOKit.hid
// k10-battery-probe: waits for the first battery report from a K10 Pro running
// the K10 Battery firmware and prints it. Only the battery marker reports are
// decoded; ordinary key reports are counted, never printed.
//
//   swift tools/k10-battery-probe.swift
//
// Needs Input Monitoring permission for the terminal app you run it from.
var total = 0
let t0 = Date()
let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x3434] as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(m, { _, _, _, dev in
    let tr = IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) ?? "" as CFTypeRef
    print(String(format: "%.0fs", Date().timeIntervalSince(t0)), "device attached, transport=\(tr)"); fflush(stdout)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { _, _, _, _, rid, rep, len in
        guard rid == 1 else { return }
        total += 1
        let b = (rep[0] == 1 && len >= 9) ? 1 : 0
        let mk = rep[b + 2]
        if mk == 0xDE || mk == 0xDF {
            let pct = (Int(rep[b + 3]) - 0xA5) * 10 + (Int(rep[b + 4]) - 0xA5)
            print(String(format: "%.0fs", Date().timeIntervalSince(t0)), "BATTERY REPORT: \(pct)% charging=\(mk == 0xDE) after \(total) reports")
            exit(0)
        }
    }, nil)
}, nil)
IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(m, 0)
RunLoop.main.run(until: Date().addingTimeInterval(480))
print("no battery report after 480s; reports seen:", total)
exit(1)
