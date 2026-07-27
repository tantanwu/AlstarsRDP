import CoreFoundation
import Foundation
import RDPDomain

public struct EnterprisePolicy: Equatable, Sendable {
    public enum Key {
        public static let automaticReconnectEnabled = "AutomaticReconnectEnabled"
        public static let maximumReconnectAttempts = "MaximumReconnectAttempts"
        public static let forcedScaleMode = "ForcedScaleMode"
        public static let maximumRedirectionPreset = "MaximumRedirectionPreset"
        public static let allowCredentialSaving = "AllowCredentialSaving"
        public static let allowPrivateDiagnosticExport = "AllowPrivateDiagnosticExport"

        static let all = [
            automaticReconnectEnabled,
            maximumReconnectAttempts,
            forcedScaleMode,
            maximumRedirectionPreset,
            allowCredentialSaving,
            allowPrivateDiagnosticExport
        ]
    }

    public static let managedConfigurationKey = "com.apple.configuration.managed"
    public static let unrestricted = EnterprisePolicy()

    public var automaticReconnectEnabled: Bool?
    public var maximumReconnectAttempts: UInt8?
    public var forcedScaleMode: DisplayConfiguration.ScaleMode?
    public var maximumRedirectionPreset: RedirectionPolicy.Preset?
    public var allowsCredentialSaving: Bool
    public var allowsPrivateDiagnosticExport: Bool

    public init(
        automaticReconnectEnabled: Bool? = nil,
        maximumReconnectAttempts: UInt8? = nil,
        forcedScaleMode: DisplayConfiguration.ScaleMode? = nil,
        maximumRedirectionPreset: RedirectionPolicy.Preset? = nil,
        allowsCredentialSaving: Bool = true,
        allowsPrivateDiagnosticExport: Bool = true
    ) {
        self.automaticReconnectEnabled = automaticReconnectEnabled
        self.maximumReconnectAttempts = maximumReconnectAttempts
        self.forcedScaleMode = forcedScaleMode
        self.maximumRedirectionPreset = maximumRedirectionPreset
        self.allowsCredentialSaving = allowsCredentialSaving
        self.allowsPrivateDiagnosticExport = allowsPrivateDiagnosticExport
    }

    public init(managedValues: [String: Any]) {
        automaticReconnectEnabled = Self.bool(managedValues[Key.automaticReconnectEnabled])
        maximumReconnectAttempts = Self.uint8(managedValues[Key.maximumReconnectAttempts])
        forcedScaleMode = Self.string(managedValues[Key.forcedScaleMode])
            .flatMap(DisplayConfiguration.ScaleMode.init(rawValue:))
        maximumRedirectionPreset = Self.string(managedValues[Key.maximumRedirectionPreset])
            .flatMap(RedirectionPolicy.Preset.init(rawValue:))
        allowsCredentialSaving = Self.bool(managedValues[Key.allowCredentialSaving]) ?? true
        allowsPrivateDiagnosticExport = Self.bool(managedValues[Key.allowPrivateDiagnosticExport]) ?? true
    }

    public static func loadManaged(defaults: UserDefaults = .standard) -> EnterprisePolicy {
        var values = defaults.dictionary(forKey: managedConfigurationKey) ?? [:]
        for key in Key.all where defaults.objectIsForced(forKey: key) {
            values[key] = defaults.object(forKey: key)
        }
        return EnterprisePolicy(managedValues: values)
    }

    public func applying(to settings: ApplicationSettings) -> ApplicationSettings {
        var effective = settings
        effective.schemaVersion = ApplicationSettings.currentSchemaVersion
        if let automaticReconnectEnabled {
            effective.automaticReconnectEnabled = automaticReconnectEnabled
        }
        if let maximumReconnectAttempts {
            effective.defaultReconnectAttempts = min(effective.defaultReconnectAttempts, maximumReconnectAttempts)
        }
        if let forcedScaleMode { effective.defaultScaleMode = forcedScaleMode }
        if let maximumRedirectionPreset,
           Self.rank(effective.defaultRedirectionPreset) > Self.rank(maximumRedirectionPreset) {
            effective.defaultRedirectionPreset = maximumRedirectionPreset
        }
        return effective
    }

    public func applying(to profile: ConnectionProfile) -> ConnectionProfile {
        var effective = profile
        if let maximumReconnectAttempts {
            effective.reconnect.maximumAttempts = min(effective.reconnect.maximumAttempts, maximumReconnectAttempts)
        }
        if let forcedScaleMode { effective.display.scaleMode = forcedScaleMode }
        effective.redirection = applying(to: effective.redirection)
        if !allowsCredentialSaving {
            effective.credentialReference = nil
            switch effective.route {
            case let .socks5(proxy):
                var proxy = proxy
                proxy.credentialReference = nil
                effective.route = .socks5(proxy)
            case let .httpConnect(proxy, tls):
                var proxy = proxy
                proxy.credentialReference = nil
                effective.route = .httpConnect(proxy: proxy, tls: tls)
            case let .rdGateway(gateway):
                var gateway = gateway
                gateway.credentialReference = nil
                effective.route = .rdGateway(gateway)
            case .direct:
                break
            }
        }
        return effective
    }

    /// Produces a profile suitable for persistence while keeping temporary
    /// managed display, reconnect, and redirection caps out of user data.
    /// Credential references are the exception: a policy that forbids saving
    /// credentials removes them and is enforced as a storage boundary.
    public func applyingForStorage(
        to proposed: ConnectionProfile,
        preserving original: ConnectionProfile?,
        managedFieldChanges: Set<ManagedProfileField> = []
    ) -> ConnectionProfile {
        var stored = proposed
        if let original {
            if let maximumReconnectAttempts {
                if managedFieldChanges.contains(.reconnect) {
                    stored.reconnect.maximumAttempts = min(
                        proposed.reconnect.maximumAttempts,
                        maximumReconnectAttempts
                    )
                } else {
                    stored.reconnect = original.reconnect
                }
            }
            if forcedScaleMode != nil {
                stored.display.scaleMode = original.display.scaleMode
            }
            if maximumRedirectionPreset != nil {
                if managedFieldChanges.contains(.redirection) {
                    stored.redirection = redirectionForStorage(
                        proposed: proposed.redirection,
                        original: original.redirection
                    )
                } else {
                    stored.redirection = original.redirection
                }
            }
        } else {
            stored = applying(to: stored)
        }
        if !allowsCredentialSaving {
            stored = removingCredentialReferences(from: stored)
        }
        return stored
    }

    public var permittedRedirection: RedirectionPolicy {
        switch maximumRedirectionPreset {
        case .secure:
            return .defaults(for: .secure)
        case .standard:
            return .defaults(for: .standard)
        case .complete, .none:
            return Self.allRedirectionCapabilities
        }
    }

    private func applying(to redirection: RedirectionPolicy) -> RedirectionPolicy {
        guard let maximumRedirectionPreset else { return redirection }
        let permitted = permittedRedirection
        var effective = redirection
        if Self.rank(effective.preset) > Self.rank(maximumRedirectionPreset) {
            effective.preset = maximumRedirectionPreset
        }
        effective.clipboardText = effective.clipboardText && permitted.clipboardText
        effective.clipboardImages = effective.clipboardImages && permitted.clipboardImages
        effective.clipboardFiles = effective.clipboardFiles && permitted.clipboardFiles
        effective.audioPlayback = effective.audioPlayback && permitted.audioPlayback
        effective.microphone = effective.microphone && permitted.microphone
        effective.printers = effective.printers && permitted.printers
        effective.cameras = effective.cameras && permitted.cameras
        effective.smartCards = effective.smartCards && permitted.smartCards
        if maximumRedirectionPreset != .complete {
            effective.drivePaths = []
            effective.sharedFolders = []
        }
        return effective
    }

    private func redirectionForStorage(
        proposed: RedirectionPolicy,
        original: RedirectionPolicy
    ) -> RedirectionPolicy {
        guard let maximumRedirectionPreset else { return proposed }
        let permitted = permittedRedirection
        var stored = proposed
        if Self.rank(original.preset) > Self.rank(maximumRedirectionPreset),
           Self.rank(proposed.preset) >= Self.rank(maximumRedirectionPreset) {
            stored.preset = original.preset
        } else if Self.rank(stored.preset) > Self.rank(maximumRedirectionPreset) {
            stored.preset = maximumRedirectionPreset
        }
        if !permitted.clipboardText { stored.clipboardText = original.clipboardText }
        if !permitted.clipboardImages { stored.clipboardImages = original.clipboardImages }
        if !permitted.clipboardFiles { stored.clipboardFiles = original.clipboardFiles }
        if !permitted.audioPlayback { stored.audioPlayback = original.audioPlayback }
        if !permitted.microphone { stored.microphone = original.microphone }
        if !permitted.printers { stored.printers = original.printers }
        if !permitted.cameras { stored.cameras = original.cameras }
        if !permitted.smartCards { stored.smartCards = original.smartCards }
        if maximumRedirectionPreset != .complete {
            stored.drivePaths = original.drivePaths
            stored.sharedFolders = original.sharedFolders
        }
        return stored
    }

    private func removingCredentialReferences(from profile: ConnectionProfile) -> ConnectionProfile {
        var effective = profile
        effective.credentialReference = nil
        switch effective.route {
        case let .socks5(proxy):
            var proxy = proxy
            proxy.credentialReference = nil
            effective.route = .socks5(proxy)
        case let .httpConnect(proxy, tls):
            var proxy = proxy
            proxy.credentialReference = nil
            effective.route = .httpConnect(proxy: proxy, tls: tls)
        case let .rdGateway(gateway):
            var gateway = gateway
            gateway.credentialReference = nil
            effective.route = .rdGateway(gateway)
        case .direct:
            break
        }
        return effective
    }

    private static func rank(_ preset: RedirectionPolicy.Preset) -> Int {
        switch preset {
        case .secure: return 0
        case .standard: return 1
        case .complete: return 2
        }
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber,
           CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return nil
    }

    private static func uint8(_ value: Any?) -> UInt8? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let numericValue = number.doubleValue
        guard numericValue.isFinite,
              numericValue.rounded() == numericValue,
              (0...Double(UInt8.max)).contains(numericValue) else { return nil }
        return UInt8(numericValue)
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static let allRedirectionCapabilities = RedirectionPolicy(
        preset: .complete,
        clipboardText: true,
        clipboardImages: true,
        clipboardFiles: true,
        audioPlayback: true,
        microphone: true,
        printers: true,
        cameras: true,
        smartCards: true
    )
}
