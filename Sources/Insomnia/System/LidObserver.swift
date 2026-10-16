import AppKit
import CoreGraphics
import Foundation
import IOKit

/// Spec section 3: IOKit interest notification on `IOPMrootDomain`. The
/// kernel wakes us on a clamshell change; between events nothing runs.
/// A change is delivered only if the state is still the same 2 s later.
@MainActor
final class LidObserver {
    nonisolated static let debounce: TimeInterval = 2
    nonisolated static let clamshellKey = "AppleClamshellState"

    /// Called on the main actor after the debounce, with `true` for closed.
    var onChange: ((Bool) -> Void)?

    /// Last delivered state, refreshed from the registry when read.
    var isClosed: Bool {
        read() ?? lastDelivered
    }

    private let read: () -> Bool?
    private let debounce: TimeInterval
    private var lastDelivered: Bool = false
    private var pending: Bool?
    private var debounceTimer: Timer?
    private var settledWaiter: ((Bool) -> Void)?

    private var port: IONotificationPortRef?
    private var service: io_service_t = 0
    private var notification: io_object_t = 0
    private var screenObserver: NSObjectProtocol?

    /// `read` and `debounce` are injectable for tests; the app uses the
    /// registry and the 2 s debounce.
    init(read: @escaping () -> Bool? = LidObserver.readClamshellState, debounce: TimeInterval = LidObserver.debounce) {
        self.read = read
        self.debounce = debounce
    }

    /// True = closed, false = open, nil = unavailable (no IOPMrootDomain or
    /// no clamshell, e.g. a desktop). A lid closed while an external display
    /// is connected reads open: the Mac is in use in clamshell mode, so the
    /// countdown keeps running and no closed-lid action, Low Power Mode or
    /// closed-lid sleep applies.
    nonisolated static func readClamshellState() -> Bool? {
        guard let closed = readRootDomainBool(clamshellKey) else { return nil }
        return closed && !externalDisplayConnected()
    }

    /// Whether any online display is not the built-in panel. A sleeping
    /// external display still counts, so walking away from a clamshell
    /// setup does not turn it into a closed lid in a bag.
    nonisolated static func externalDisplayConnected() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// A boolean property of IOPMrootDomain; nil when the service or the
    /// property is missing.
    nonisolated static func readRootDomainBool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue)
    }

    func start() {
        guard port == nil else { return }
        lastDelivered = read() ?? false
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            Log.error("lid observer: IOPMrootDomain not found")
            return
        }
        guard let p = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.error("lid observer: IONotificationPortCreate failed")
            IOObjectRelease(service)
            service = 0
            return
        }
        port = p
        let source = IONotificationPortGetRunLoopSource(p).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddInterestNotification(p, service, kIOGeneralInterest, Self.callback, refcon, &notification)
        guard kr == KERN_SUCCESS else {
            Log.error("lid observer: IOServiceAddInterestNotification failed (\(kr))")
            stop()
            return
        }
        // A display connected or disconnected with the lid shut changes the
        // state read above without a clamshell message.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleInterest() }
        }
        Log.info("lid observer started (lid \(lastDelivered ? "closed" : "open"))")
    }

    func stop() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        pending = nil
        settledWaiter = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if let p = port {
            let source = IONotificationPortGetRunLoopSource(p).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            IONotificationPortDestroy(p)
            port = nil
        }
        if service != 0 {
            IOObjectRelease(service)
            service = 0
        }
    }

    /// Runs `body` once no lid change is waiting out the debounce: at once
    /// if none is, otherwise when the change is delivered (`true`, after
    /// `onChange` has run) or dropped as a flap (`false`). A caller that
    /// acts on the lid state waits here so it never acts on the state a
    /// pending change is about to replace. One waiter at a time: a newer
    /// one replaces it. `stop` drops it.
    func whenSettled(_ body: @escaping (_ delivered: Bool) -> Void) {
        guard pending != nil else {
            body(false)
            return
        }
        settledWaiter = body
    }

    /// Any message from IOPMrootDomain: re-read the registry and debounce.
    /// Internal so a test can deliver one.
    func handleInterest() {
        guard let now = read() else { return }
        guard now != lastDelivered else {
            // Flapped back to the delivered state; drop the pending change.
            if pending != nil {
                pending = nil
                debounceTimer?.invalidate()
                debounceTimer = nil
                settled(delivered: false)
            }
            return
        }
        guard pending != now else { return }
        pending = now
        debounceTimer?.invalidate()
        let timer = Timer(timeInterval: debounce, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.settle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    // MARK: Private

    private static let callback: IOServiceInterestCallback = { refcon, _, _, _ in
        guard let refcon else { return }
        let observer = Unmanaged<LidObserver>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { observer.handleInterest() }
    }

    private func settle() {
        debounceTimer = nil
        guard let candidate = pending else { return }
        pending = nil
        guard let now = read(), now == candidate, now != lastDelivered else {
            Log.info("lid observer: change flapped within \(Int(debounce)) s, ignored")
            settled(delivered: false)
            return
        }
        lastDelivered = now
        Log.info("lid \(now ? "closed" : "open")")
        onChange?(now)
        settled(delivered: true)
    }

    private func settled(delivered: Bool) {
        let waiter = settledWaiter
        settledWaiter = nil
        waiter?(delivered)
    }
}
