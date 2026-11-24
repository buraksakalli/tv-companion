import AppKit
import IOKit.pwr_mgt

/// Mac lifecycle events we automate on.
enum SystemEvent: String, Sendable {
    case displaySleep, displayWake, screenLocked, screenUnlocked, systemWillSleep, shutdown
}

/// Bridges NSWorkspace, distributed notifications and IOKit power messages.
/// System sleep goes through IOKit so we can hold sleep for a few seconds while the
/// power-off command is sent (NSWorkspace's willSleep can't delay sleep).
@MainActor
final class SystemEvents {
    /// Called for every event. For `.systemWillSleep`, call `done` when finished; sleep
    /// proceeds after `done` or after `sleepGrace`, whichever comes first.
    var handler: (@MainActor (SystemEvent, _ done: @escaping @MainActor () -> Void) -> Void)?
    var sleepGrace: Duration = .seconds(5)

    private var tokens: [NSObjectProtocol] = []
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notifyPort: IONotificationPortRef?

    // iokit_common_msg(x) = 0xE0000000 | x (macros aren't imported into Swift).
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.screensDidSleepNotification, .displaySleep)
        observe(ws, NSWorkspace.screensDidWakeNotification, .displayWake)
        observe(ws, NSWorkspace.willPowerOffNotification, .shutdown)
        let dnc = DistributedNotificationCenter.default()
        observe(dnc, Notification.Name("com.apple.screenIsLocked"), .screenLocked)
        observe(dnc, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked)
        registerForSystemPower()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: SystemEvent) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler?(event) {} }
        })
    }

    private func registerForSystemPower() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let arg = Int(bitPattern: argument)
            MainActor.assumeIsolated {
                Unmanaged<SystemEvents>.fromOpaque(refcon).takeUnretainedValue().power(messageType, arg)
            }
        }, &notifier)
        if rootPort != 0, let notifyPort {
            IONotificationPortSetDispatchQueue(notifyPort, .main)
        }
    }

    private func power(_ message: UInt32, _ argument: Int) {
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, argument)
        case Self.systemWillSleep:
            final class Once { var fired = false }
            let once = Once()
            let port = rootPort
            let allow: @MainActor () -> Void = {
                guard !once.fired else { return }
                once.fired = true
                IOAllowPowerChange(port, argument)
            }
            if let handler { handler(.systemWillSleep, allow) } else { allow() }
            let grace = sleepGrace
            Task { @MainActor in
                try? await Task.sleep(for: grace)
                allow()
            }
        default:
            break
        }
    }
}
