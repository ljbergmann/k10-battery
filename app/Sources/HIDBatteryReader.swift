import Foundation
import IOKit.hid

/// Talks to the Keychron K10 Pro over IOKit HID:
///  - decodes the battery report the K10 Battery firmware sends as reserved
///    Keyboard-page usages (see firmware/battery_broadcast.c);
///  - asks the keyboard for a fresh reading by pulsing its Kana LED output.
///
/// Privacy: every report that doesn't match the battery pattern is dropped
/// unread. Key data is never stored, logged or forwarded.
final class HIDBatteryReader {
    struct Reading {
        let percent: Int        // the firmware's own estimate (as Fn+B)
        let charging: Bool      // USB power connected
        let millivolts: Int?    // nil with older firmware
    }

    static let vendorID = 0x3434      // Keychron
    static let productIDs = [0x02A0, 0x02A1, 0x02A2, 0x02A3, 0x02A4, 0x02A5] // K10 Pro ANSI/ISO/JIS, RGB/white

    var onReading: ((Reading) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    /// USB product ID of the connected K10 Pro variant (0 until one is seen).
    private(set) var productID = 0

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private var kanaElements: [IOHIDDevice: IOHIDElement] = [:]
    private var started = false
    private static let bufferSize = 64

    static var hasAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    var isConnected: Bool { !buffers.isEmpty }

    func start() {
        if started { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        started = true
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

    /// Ask the keyboard to send a reading now: Kana LED off -> on -> off.
    /// The firmware answers as soon as no key is held (needs Bluetooth).
    func requestReading() {
        for (device, kana) in kanaElements {
            set(kana, on: device, to: 0)
            set(kana, on: device, to: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.set(kana, on: device, to: 0)
            }
        }
    }

    private func set(_ element: IOHIDElement, on device: IOHIDDevice, to v: Int) {
        let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, mach_absolute_time(), v)
        IOHIDDeviceSetValue(device, element, value)
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

        let match = [kIOHIDElementUsagePageKey: kHIDPage_LEDs, kIOHIDElementUsageKey: kHIDUsage_LED_Kana] as CFDictionary
        if let els = IOHIDDeviceCopyMatchingElements(device, match, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement],
           let kana = els.first(where: { IOHIDElementGetType($0) == kIOHIDElementTypeOutput }) {
            kanaElements[device] = kana
        }
        onConnectionChange?(true)
    }

    private func detach(_ device: IOHIDDevice) {
        if let buf = buffers.removeValue(forKey: device) { buf.deallocate() }
        kanaElements.removeValue(forKey: device)
        onConnectionChange?(isConnected)
    }

    /// Report ID 1 = boot-style keyboard report: [id, mods, reserved, k1..k6].
    ///   k1 = 0xDE (charging) / 0xDF (on battery)
    ///   k2 = 0xA5 + tens, k3 = 0xA5 + units of percent
    ///   k4..k6 = voltage, three base-11 digits (0xA5 + digit): mV = 3000 + 2*d
    ///            (all zero with firmware v1.0.0, which sent no voltage)
    private func handle(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard reportID == 1, length >= 8 else { return }
        let base = (report[0] == 1 && length >= 9) ? 1 : 0
        guard length >= base + 8, report[base] == 0 else { return }  // no modifiers
        let marker = report[base + 2]
        guard marker == 0xDE || marker == 0xDF else { return }

        func digit(_ i: Int) -> Int? {
            let v = Int(report[base + i])
            return (0xA5...0xAF).contains(v) ? v - 0xA5 : nil
        }
        guard let tens = digit(3), let units = digit(4) else { return }
        let pct = tens * 10 + units
        guard pct <= 100 else { return }

        var mv: Int?
        let k = (5..<8).map { Int(report[base + $0]) }
        if k.allSatisfy({ $0 == 0 }) {
            mv = nil
        } else if let a = digit(5), let b = digit(6), let c = digit(7) {
            mv = 3000 + 2 * (a * 121 + b * 11 + c)
        } else {
            return
        }
        onReading?(Reading(percent: pct, charging: marker == 0xDE, millivolts: mv))
    }
}
