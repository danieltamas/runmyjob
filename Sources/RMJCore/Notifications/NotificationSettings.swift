import Foundation

/// Which alerts RMJ raises (Settings > Notifications), kept in `config.json`.
public struct NotificationSettings: Sendable, Equatable {
    /// A failed or lost job.
    public var failures = true
    /// A destination that went unreachable while a job ran on it.
    public var unreachable = true
    /// A job that finished ok.
    public var done = false

    public init() {}

    public static func load(home: RMJHome) -> NotificationSettings {
        let object = ConfigFile.read(home)
        var settings = NotificationSettings()
        settings.failures = ConfigFile.flag(object, "notify_failures", fallback: settings.failures)
        settings.unreachable = ConfigFile.flag(object, "notify_unreachable", fallback: settings.unreachable)
        settings.done = ConfigFile.flag(object, "notify_done", fallback: settings.done)
        return settings
    }

    public static func save(_ settings: NotificationSettings, home: RMJHome) throws {
        try ConfigFile.merge(["notify_failures": settings.failures, "notify_unreachable": settings.unreachable,
                              "notify_done": settings.done], home: home)
    }

    /// Changes one switch and leaves the other keys of `config.json` as they are, under the file's lock.
    public static func set(_ switchKey: WritableKeyPath<NotificationSettings, Bool>, to on: Bool, home: RMJHome) throws {
        let name = switch switchKey {
        case \.failures: "notify_failures"
        case \.unreachable: "notify_unreachable"
        default: "notify_done"
        }
        try ConfigFile.merge([name: on], home: home)
    }
}
