import Foundation
import IOKit.hid

/// Observes HID-level plug/unplug events for FIDO usage page devices.
///
/// `@unchecked Sendable`: the IOKit callbacks arrive on the main run loop and the debounce
/// runs on `callbackQueue`; `pendingWorkItem` is touched only on that queue, and `manager`
/// only in `init` and `deinit`.
final class DeviceMonitorService: @unchecked Sendable {
    private let notify: @Sendable () -> Void
    private var manager: IOHIDManager?
    private let debounceInterval: TimeInterval
    private let callbackQueue = DispatchQueue(label: "com.fidopass.deviceMonitor", qos: .userInitiated)
    private var pendingWorkItem: DispatchWorkItem?

    init(debounceInterval: TimeInterval = 0.35, notify: @escaping @Sendable () -> Void) {
        self.debounceInterval = debounceInterval
        self.notify = notify
        setUp()
    }

    deinit {
        tearDown()
    }

    private func setUp() {
        let options = IOOptionBits(kIOHIDOptionsTypeNone)
        let created = IOHIDManagerCreate(kCFAllocatorDefault, options)
        guard CFGetTypeID(created) == IOHIDManagerGetTypeID() else { return }
        manager = created

        let matchDictionary: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: NSNumber(value: 0xF1D0) // FIDO usage page
        ]
        IOHIDManagerSetDeviceMatching(created, matchDictionary as CFDictionary)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(created, { context, _, _, _ in
            DeviceMonitorService.trigger(from: context)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(created, { context, _, _, _ in
            DeviceMonitorService.trigger(from: context)
        }, context)

        IOHIDManagerScheduleWithRunLoop(created, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(created, options)
    }

    private func tearDown() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private static func trigger(from context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        let monitor = Unmanaged<DeviceMonitorService>.fromOpaque(context).takeUnretainedValue()
        monitor.scheduleNotification()
    }

    private func scheduleNotification() {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.pendingWorkItem?.cancel()
            let notify = self.notify
            let workItem = DispatchWorkItem {
                DispatchQueue.main.async { notify() }
            }
            self.pendingWorkItem = workItem
            self.callbackQueue.asyncAfter(deadline: .now() + self.debounceInterval, execute: workItem)
        }
    }
}
