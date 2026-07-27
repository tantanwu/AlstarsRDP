import Foundation
import RDPDomain

public struct ApplicationSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var automaticReconnectEnabled: Bool
    public var defaultReconnectAttempts: UInt8
    public var defaultScaleMode: DisplayConfiguration.ScaleMode
    public var defaultRedirectionPreset: RedirectionPolicy.Preset

    public init(
        schemaVersion: Int = currentSchemaVersion,
        automaticReconnectEnabled: Bool = true,
        defaultReconnectAttempts: UInt8 = 3,
        defaultScaleMode: DisplayConfiguration.ScaleMode = .dynamicResolution,
        defaultRedirectionPreset: RedirectionPolicy.Preset = .secure
    ) {
        self.schemaVersion = schemaVersion
        self.automaticReconnectEnabled = automaticReconnectEnabled
        self.defaultReconnectAttempts = defaultReconnectAttempts
        self.defaultScaleMode = defaultScaleMode
        self.defaultRedirectionPreset = defaultRedirectionPreset
    }
}

public final class ApplicationSettingsStore: @unchecked Sendable {
    public let policy: EnterprisePolicy
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "application-settings-v1",
        policy: EnterprisePolicy = .unrestricted
    ) {
        self.defaults = defaults
        self.key = key
        self.policy = policy
    }

    public func load() -> ApplicationSettings {
        lock.lock(); defer { lock.unlock() }
        return policy.applying(to: loadStoredLocked())
    }

    public func loadStored() -> ApplicationSettings {
        lock.lock(); defer { lock.unlock() }
        return loadStoredLocked()
    }

    public func save(_ settings: ApplicationSettings) throws {
        var stored = settings
        stored.schemaVersion = ApplicationSettings.currentSchemaVersion
        let data = try JSONEncoder().encode(stored)
        lock.lock(); defer { lock.unlock() }
        defaults.set(data, forKey: key)
    }

    public func restoreDefaults() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    private func loadStoredLocked() -> ApplicationSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(ApplicationSettings.self, from: data),
              (1...ApplicationSettings.currentSchemaVersion).contains(settings.schemaVersion) else {
            return ApplicationSettings()
        }
        return settings
    }
}
