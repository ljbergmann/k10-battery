import Foundation
import IOKit.hid

/// Listens to the Keychron K10 Pro over IOKit HID and decodes the battery
/// level that the custom firmware hides in the reserved byte of an empty
/// keyboard report (see firmware keymap "battery").
///
/// Privacy: only that reserved byte is inspected. Key data is never stored,
/// logged or forwarded.
final class HIDBatteryReader {
    struct Reading { let percent: Int; let charging: Bool }

    static let vendorID = 0x3434      // Keychron
    static let productIDs = [0x02A0, 0x02A1, 0x02A2, 0x02A3, 0x02A4, 0x02A5] // K10 Pro ANSI/ISO/JIS, RGB/white

    var onReading: ((Reading) -> Void)?
    /// USB product ID of the connected K10 Pro variant (0 until one is seen).
    private(set) var productID = 0
    var onConnectionChange: ((Bool) -> Void)?

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private static let bufferSize = 64

    static var hasAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() {
        let matches = Self.productIDs.map {
            [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: $0,
             kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 6] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<HIDBatteryReader>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<HIDBatteryReader>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ device: IOHIDDevice) {
        guard buffers[device] == nil else { return }
        productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? productID
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
        buffers[device] = buf
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, Self.bufferSize, { ctx, _, _, _, reportID, report, length in
            Unmanaged<HIDBatteryReader>.fromOpaque(ctx!).takeUnretainedValue()
                .handle(reportID: reportID, report: report, length: length)
        }, ctx)
        onConnectionChange?(true)
    }

    private func detach(_ device: IOHIDDevice) {
        if let buf = buffers.removeValue(forKey: device) { buf.deallocate() }
        onConnectionChange?(!buffers.isEmpty)
    }

    /// Report ID 1 = boot-style keyboard report: [id, mods, reserved, k1..k6].
    /// The firmware encodes the battery as reserved HID usages:
    ///   k1 = 0xDE (charging) / 0xDF (on battery), k2 = 0xA5 + tens, k3 = 0xA5 + units.
    /// Any report that isn't exactly this shape is ignored without being looked at further.
    private func handle(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard reportID == 1, length >= 8 else { return }
        let base = (report[0] == 1 && length >= 9) ? 1 : 0
        guard report[base] == 0 else { return }                        // no modifiers
        let marker = report[base + 2]
        guard marker == 0xDE || marker == 0xDF else { return }
        let tens = Int(report[base + 3]) - 0xA5, units = Int(report[base + 4]) - 0xA5
        guard (0...10).contains(tens), (0...9).contains(units) else { return }
        for i in (base + 5)..<min(base + 8, length) where report[i] != 0 { return }
        let pct = tens * 10 + units
        guard pct <= 100 else { return }
        onReading?(Reading(percent: pct, charging: marker == 0xDE))
    }
}
