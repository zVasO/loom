import Foundation

/// The extensions' alarms (ADR-0012): named, per extension, fired by Loom's
/// own clock. A page's JavaScript timers are throttled when its view is
/// hidden — a break must not start minutes late because the Pomodoro tab was
/// not on screen. Alarms live as long as the app: a page re-creates them from
/// its own stored state when it loads.
@MainActor
public final class ExtensionAlarmScheduler {
    public typealias Fire = @MainActor (_ extensionID: String, _ name: String, _ scheduledTime: Date) -> Void

    private struct Key: Hashable {
        let extensionID: String
        let name: String
    }

    private var tasks: [Key: Task<Void, Never>] = [:]
    private var dates: [Key: Date] = [:]
    /// Set once the owner can receive — it may need `self` to be complete first.
    public var onFire: Fire?

    public init(onFire: Fire? = nil) {
        self.onFire = onFire
    }

    /// Creates or replaces the alarm `name` of an extension.
    public func schedule(_ name: String, at date: Date, for extensionID: String) throws {
        let key = Key(extensionID: extensionID, name: name)
        if dates[key] == nil, alarms(for: extensionID).count >= BridgeAlarmParams.maxAlarms {
            throw BridgeError(.conflict, "an extension holds at most \(BridgeAlarmParams.maxAlarms) alarms")
        }
        tasks[key]?.cancel()
        dates[key] = date
        tasks[key] = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            // The continuous clock keeps counting while the Mac sleeps: an alarm
            // due during the night fires on wake, not a night late.
            try? await Task.sleep(for: .milliseconds(Int64(delay * 1000)), clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.fire(key, date)
        }
    }

    private func fire(_ key: Key, _ date: Date) {
        guard dates[key] == date else { return }
        tasks[key] = nil
        dates[key] = nil
        onFire?(key.extensionID, key.name, date)
    }

    public func clear(_ name: String, for extensionID: String) {
        let key = Key(extensionID: extensionID, name: name)
        tasks.removeValue(forKey: key)?.cancel()
        dates.removeValue(forKey: key)
    }

    public func clearAll(for extensionID: String) {
        for key in tasks.keys where key.extensionID == extensionID {
            tasks.removeValue(forKey: key)?.cancel()
            dates.removeValue(forKey: key)
        }
    }

    public func alarms(for extensionID: String) -> [BridgeAlarm] {
        dates.filter { $0.key.extensionID == extensionID }
            .map { BridgeAlarm(name: $0.key.name, scheduledTime: ($0.value.timeIntervalSince1970 * 1000).rounded()) }
            .sorted { $0.scheduledTime < $1.scheduledTime }
    }
}
