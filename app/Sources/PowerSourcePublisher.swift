import Foundation
import IOKit

// IOKit power-source publishing. Exported by IOKit and documented in IOPSKeys.h
// ("Clients of IOPSCreatePowerSource must specify these keys"), but the
// prototypes are not in the public headers, so we declare them here.
@_silgen_name("IOPSCreatePowerSource")
private func IOPSCreatePowerSource(_ out: UnsafeMutablePointer<OpaquePointer?>, _ type: CFString) -> IOReturn
@_silgen_name("IOPSSetPowerSourceDetails")
private func IOPSSetPowerSourceDetails(_ ps: OpaquePointer, _ details: CFDictionary) -> IOReturn
@_silgen_name("IOPSReleasePowerSource")
private func IOPSReleasePowerSource(_ ps: OpaquePointer) -> IOReturn

/// Publishes the K10 Pro as a Bluetooth accessory power source, which makes it
/// appear in macOS's own Batteries widget (and `pmset -g accps`) next to the
/// AirPods / MX Master. The entry lives as long as this process holds it.
final class PowerSourcePublisher {
    private var handle: OpaquePointer?
    private static let identifier = "4D4D8345-6DA5-4BAD-96BF-C52F8E9899F6" // random, fixed

    func publish(percent: Int, charging: Bool, productID: Int, minutesToEmpty: Int? = nil) {
        if handle == nil {
            var ps: OpaquePointer?
            guard IOPSCreatePowerSource(&ps, "Accessory Source" as CFString) == kIOReturnSuccess, let ps else {
                NSLog("K10Battery: IOPSCreatePowerSource failed"); return
            }
            handle = ps
        }
        var details: [String: Any] = [
            "Type": "Accessory Source",
            "Accessory Category": "Keyboard",
            "Accessory Identifier": Self.identifier,
            "Name": "Keychron K10 Pro",
            "Current Capacity": max(0, min(100, percent)),
            "Max Capacity": 100,
            "Power Source State": charging ? "AC Power" : "Battery Power",
            "Is Charging": charging,
            "Is Present": true,
            "Transport Type": "Bluetooth",
            "Vendor ID": HIDBatteryReader.vendorID,
            "Product ID": productID,
            "Vendor ID Source": 2,
            "Low Warn Level": 15,
        ]
        if let m = minutesToEmpty, !charging { details["Time to Empty"] = m }
        if IOPSSetPowerSourceDetails(handle!, details as CFDictionary) != kIOReturnSuccess {
            NSLog("K10Battery: IOPSSetPowerSourceDetails failed")
        }
    }

    /// Removes the entry (keyboard disconnected / app quitting).
    func withdraw() {
        if let h = handle { _ = IOPSReleasePowerSource(h) }
        handle = nil
    }

    deinit { withdraw() }
}
