import Foundation

public struct Endpoint: Codable, Equatable, Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
    }

    public func validated(field: String = "endpoint") throws -> Endpoint {
        guard !host.isEmpty else { throw ProfileValidationError.emptyHost(field) }
        guard !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !host.unicodeScalars.contains(where: { CharacterSet(charactersIn: "/\\@?#[]").contains($0) }),
              host.utf8.count <= 255 else {
            throw ProfileValidationError.invalidHost(field)
        }
        guard port > 0 else { throw ProfileValidationError.invalidPort(field) }
        return self
    }
}

public struct TargetIdentity: Codable, Equatable, Hashable, Sendable {
    public var endpoint: Endpoint
    public var certificateName: String

    public init(endpoint: Endpoint, certificateName: String? = nil) {
        self.endpoint = endpoint
        self.certificateName = certificateName ?? endpoint.host
    }

    public func validated() throws -> TargetIdentity {
        _ = try endpoint.validated(field: "target")
        guard !certificateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileValidationError.emptyCertificateName
        }
        guard !certificateName.contains(where: { $0.isWhitespace || $0.isNewline }),
              !certificateName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !certificateName.unicodeScalars.contains(where: { CharacterSet(charactersIn: "/\\@?#[]").contains($0) }),
              certificateName.utf8.count <= 255 else {
            throw ProfileValidationError.invalidCertificateName
        }
        return self
    }
}

public struct CredentialReference: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case target
        case proxy
        case gateway
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public struct ProxyConfiguration: Codable, Equatable, Hashable, Sendable {
    public var endpoint: Endpoint
    public var usernameHint: String
    public var credentialReference: CredentialReference?
    public var resolvesTargetName: Bool

    public init(
        endpoint: Endpoint,
        usernameHint: String = "",
        credentialReference: CredentialReference? = nil,
        resolvesTargetName: Bool = true
    ) {
        self.endpoint = endpoint
        self.usernameHint = usernameHint
        self.credentialReference = credentialReference
        self.resolvesTargetName = resolvesTargetName
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint, usernameHint, credentialReference, resolvesTargetName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decode(Endpoint.self, forKey: .endpoint)
        usernameHint = try container.decodeIfPresent(String.self, forKey: .usernameHint) ?? ""
        credentialReference = try container.decodeIfPresent(CredentialReference.self, forKey: .credentialReference)
        resolvesTargetName = try container.decodeIfPresent(Bool.self, forKey: .resolvesTargetName) ?? true
    }

    public var expectsCredentials: Bool {
        !usernameHint.isEmpty || credentialReference != nil
    }
}

public struct GatewayConfiguration: Codable, Equatable, Hashable, Sendable {
    public enum Transport: String, Codable, Sendable {
        case auto
        case rpc
        case http
    }

    public var endpoint: Endpoint
    public var credentialReference: CredentialReference?
    public var transport: Transport

    public init(
        endpoint: Endpoint,
        credentialReference: CredentialReference? = nil,
        transport: Transport = .auto
    ) {
        self.endpoint = endpoint
        self.credentialReference = credentialReference
        self.transport = transport
    }
}

public enum RouteConfiguration: Codable, Equatable, Hashable, Sendable {
    case direct
    case socks5(ProxyConfiguration)
    case httpConnect(proxy: ProxyConfiguration, tls: Bool)
    case rdGateway(GatewayConfiguration)

    public func validated() throws -> RouteConfiguration {
        switch self {
        case .direct:
            break
        case let .socks5(proxy), let .httpConnect(proxy, _):
            _ = try proxy.endpoint.validated(field: "proxy")
            try validateProfileHint(proxy.usernameHint, field: "proxy username")
            guard proxy.resolvesTargetName else {
                throw ProfileValidationError.unsupportedProxyNameResolution
            }
            if let reference = proxy.credentialReference, reference.kind != .proxy {
                throw ProfileValidationError.wrongCredentialKind
            }
        case let .rdGateway(gateway):
            _ = try gateway.endpoint.validated(field: "gateway")
            if let reference = gateway.credentialReference, reference.kind != .gateway {
                throw ProfileValidationError.wrongCredentialKind
            }
        }
        return self
    }
}

public enum KeyboardMode: String, Codable, CaseIterable, Sendable {
    case macPreferred
    case windowsPreferred
}

public struct DisplayConfiguration: Codable, Equatable, Hashable, Sendable {
    public static let maximumDimension: UInt32 = 16_384
    public static let maximumPixelCount: UInt64 = 64 * 1024 * 1024

    public enum ScaleMode: String, Codable, Sendable {
        case fit
        case actualSize
        case dynamicResolution
    }

    public var width: UInt32
    public var height: UInt32
    public var scaleMode: ScaleMode
    public var useAllDisplays: Bool
    public var keyboardMode: KeyboardMode

    public init(
        width: UInt32 = 1920,
        height: UInt32 = 1080,
        scaleMode: ScaleMode = .dynamicResolution,
        useAllDisplays: Bool = false,
        keyboardMode: KeyboardMode = .macPreferred
    ) {
        self.width = width
        self.height = height
        self.scaleMode = scaleMode
        self.useAllDisplays = useAllDisplays
        self.keyboardMode = keyboardMode
    }
}

public struct RedirectionPolicy: Codable, Equatable, Hashable, Sendable {
    public enum Preset: String, Codable, CaseIterable, Sendable {
        case secure
        case standard
        case complete
    }

    public var preset: Preset
    public var clipboardText: Bool
    public var clipboardImages: Bool
    public var clipboardFiles: Bool
    public var audioPlayback: Bool
    public var microphone: Bool
    /// Kept for decoding schema-v1 profiles. New profiles use `sharedFolders`
    /// so filesystem access always originates from an explicit user choice.
    public var drivePaths: [String]
    public var sharedFolders: [SharedFolderBookmark]
    public var printers: Bool
    public var cameras: Bool
    public var smartCards: Bool

    public init(
        preset: Preset = .secure,
        clipboardText: Bool = true,
        clipboardImages: Bool = true,
        clipboardFiles: Bool = false,
        audioPlayback: Bool = true,
        microphone: Bool = false,
        drivePaths: [String] = [],
        sharedFolders: [SharedFolderBookmark] = [],
        printers: Bool = false,
        cameras: Bool = false,
        smartCards: Bool = false
    ) {
        self.preset = preset
        self.clipboardText = clipboardText
        self.clipboardImages = clipboardImages
        self.clipboardFiles = clipboardFiles
        self.audioPlayback = audioPlayback
        self.microphone = microphone
        self.drivePaths = drivePaths
        self.sharedFolders = sharedFolders
        self.printers = printers
        self.cameras = cameras
        self.smartCards = smartCards
    }

    public static let secure = RedirectionPolicy.defaults(for: .secure)

    public static func defaults(for preset: Preset) -> RedirectionPolicy {
        switch preset {
        case .secure:
            return RedirectionPolicy(preset: .secure, clipboardText: true, clipboardImages: false, audioPlayback: true)
        case .standard:
            return RedirectionPolicy(preset: .standard, clipboardText: true, clipboardImages: true, audioPlayback: true)
        case .complete:
            return RedirectionPolicy(
                preset: .complete,
                clipboardText: true,
                clipboardImages: true,
                clipboardFiles: true,
                audioPlayback: true,
                microphone: true,
                printers: true,
                smartCards: true
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case preset, clipboardText, clipboardImages, clipboardFiles, audioPlayback, microphone
        case drivePaths, sharedFolders, printers, cameras, smartCards
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = try container.decodeIfPresent(Preset.self, forKey: .preset) ?? .secure
        clipboardText = try container.decodeIfPresent(Bool.self, forKey: .clipboardText) ?? true
        clipboardImages = try container.decodeIfPresent(Bool.self, forKey: .clipboardImages) ?? true
        clipboardFiles = try container.decodeIfPresent(Bool.self, forKey: .clipboardFiles) ?? false
        audioPlayback = try container.decodeIfPresent(Bool.self, forKey: .audioPlayback) ?? true
        microphone = try container.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
        drivePaths = try container.decodeIfPresent([String].self, forKey: .drivePaths) ?? []
        sharedFolders = try container.decodeIfPresent([SharedFolderBookmark].self, forKey: .sharedFolders) ?? []
        printers = try container.decodeIfPresent(Bool.self, forKey: .printers) ?? false
        cameras = try container.decodeIfPresent(Bool.self, forKey: .cameras) ?? false
        smartCards = try container.decodeIfPresent(Bool.self, forKey: .smartCards) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preset, forKey: .preset)
        try container.encode(clipboardText, forKey: .clipboardText)
        try container.encode(clipboardImages, forKey: .clipboardImages)
        try container.encode(clipboardFiles, forKey: .clipboardFiles)
        try container.encode(audioPlayback, forKey: .audioPlayback)
        try container.encode(microphone, forKey: .microphone)
        // `drivePaths` is decode-only compatibility data. Re-encoding a legacy
        // absolute path would leak local filesystem details into backups.
        try container.encode(sharedFolders, forKey: .sharedFolders)
        try container.encode(printers, forKey: .printers)
        try container.encode(cameras, forKey: .cameras)
        try container.encode(smartCards, forKey: .smartCards)
    }
}

public struct SharedFolderBookmark: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let maximumDisplayNameBytes = 512
    public static let maximumBookmarkBytes = 1024 * 1024

    public var id: UUID
    public var displayName: String
    public var bookmarkData: Data

    public init(id: UUID = UUID(), displayName: String, bookmarkData: Data) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
    }
}

public struct ReconnectPolicy: Codable, Equatable, Hashable, Sendable {
    public var maximumAttempts: UInt8
    public var initialDelayMilliseconds: UInt32
    public var maximumDelayMilliseconds: UInt32

    public init(
        maximumAttempts: UInt8 = 3,
        initialDelayMilliseconds: UInt32 = 1_000,
        maximumDelayMilliseconds: UInt32 = 15_000
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialDelayMilliseconds = initialDelayMilliseconds
        self.maximumDelayMilliseconds = maximumDelayMilliseconds
    }
}

public struct ConnectionProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var schemaVersion: Int
    public var name: String
    public var target: TargetIdentity
    public var usernameHint: String
    public var domainHint: String
    public var credentialReference: CredentialReference?
    public var route: RouteConfiguration
    public var display: DisplayConfiguration
    public var redirection: RedirectionPolicy
    public var reconnect: ReconnectPolicy
    public var tags: [String]
    public var isFavorite: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        target: TargetIdentity,
        usernameHint: String = "",
        domainHint: String = "",
        credentialReference: CredentialReference? = nil,
        route: RouteConfiguration = .direct,
        display: DisplayConfiguration = DisplayConfiguration(),
        redirection: RedirectionPolicy = .secure,
        reconnect: ReconnectPolicy = ReconnectPolicy(),
        tags: [String] = [],
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.target = target
        self.usernameHint = usernameHint
        self.domainHint = domainHint
        self.credentialReference = credentialReference
        self.route = route
        self.display = display
        self.redirection = redirection
        self.reconnect = reconnect
        self.tags = tags
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConnectedAt = lastConnectedAt
    }

    public func validated() throws -> ConnectionProfile {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw ProfileValidationError.unsupportedSchema(schemaVersion)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ProfileValidationError.emptyName
        }
        guard name.utf8.count <= 256, !Self.containsControlCharacters(name) else {
            throw ProfileValidationError.invalidName
        }
        try validateProfileHint(usernameHint, field: "username")
        try validateProfileHint(domainHint, field: "domain")
        guard tags.count <= 64,
              tags.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !Self.containsControlCharacters($0) }) else {
            throw ProfileValidationError.invalidTags
        }
        guard redirection.sharedFolders.count <= 64,
              redirection.sharedFolders.allSatisfy({ bookmark in
                  !bookmark.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  bookmark.displayName.utf8.count <= SharedFolderBookmark.maximumDisplayNameBytes &&
                  !Self.containsControlCharacters(bookmark.displayName) &&
                  !bookmark.bookmarkData.isEmpty &&
                  bookmark.bookmarkData.count <= SharedFolderBookmark.maximumBookmarkBytes
              }) else {
            throw ProfileValidationError.invalidSharedFolders
        }
        _ = try target.validated()
        _ = try route.validated()
        if let reference = credentialReference, reference.kind != .target {
            throw ProfileValidationError.wrongCredentialKind
        }
        let pixelCount = UInt64(display.width) * UInt64(display.height)
        guard display.width >= 320, display.height >= 200,
              display.width <= DisplayConfiguration.maximumDimension,
              display.height <= DisplayConfiguration.maximumDimension,
              pixelCount <= DisplayConfiguration.maximumPixelCount else {
            throw ProfileValidationError.invalidDesktopSize
        }
        guard reconnect.initialDelayMilliseconds >= 100,
              reconnect.maximumDelayMilliseconds >= reconnect.initialDelayMilliseconds,
              reconnect.maximumDelayMilliseconds <= 300_000 else {
            throw ProfileValidationError.invalidReconnectPolicy
        }
        return self
    }

    public var credentialReferences: Set<CredentialReference> {
        var references = Set<CredentialReference>()
        if let credentialReference { references.insert(credentialReference) }
        switch route {
        case let .socks5(proxy), let .httpConnect(proxy, _):
            if let reference = proxy.credentialReference { references.insert(reference) }
        case let .rdGateway(gateway):
            if let reference = gateway.credentialReference { references.insert(reference) }
        case .direct:
            break
        }
        return references
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

private func validateProfileHint(_ value: String, field: String) throws {
    guard value.utf8.count <= 512,
          !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw ProfileValidationError.invalidTextField(field)
    }
}

public enum ProfileValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyName
    case invalidName
    case emptyHost(String)
    case invalidHost(String)
    case invalidPort(String)
    case emptyCertificateName
    case invalidCertificateName
    case invalidDesktopSize
    case invalidReconnectPolicy
    case invalidTextField(String)
    case invalidTags
    case invalidSharedFolders
    case unsupportedProxyNameResolution
    case wrongCredentialKind
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Connection name is required."
        case .invalidName: return "The connection name is invalid or too long."
        case let .emptyHost(field): return "The \(field) host is required."
        case let .invalidHost(field): return "The \(field) host is invalid."
        case let .invalidPort(field): return "The \(field) port must be between 1 and 65535."
        case .emptyCertificateName: return "A certificate identity is required."
        case .invalidCertificateName: return "The certificate identity is invalid."
        case .invalidDesktopSize: return "The desktop size is outside the supported bounds."
        case .invalidReconnectPolicy: return "The reconnect delay settings are outside the supported bounds."
        case let .invalidTextField(field): return "The \(field) value contains unsupported characters or is too long."
        case .invalidTags: return "The connection tags are invalid or exceed the supported limits."
        case .invalidSharedFolders: return "The shared-folder authorization data is invalid or exceeds the supported limits."
        case .unsupportedProxyNameResolution:
            return "Local target-name resolution for proxy routes is not supported by this version."
        case .wrongCredentialKind: return "The credential reference does not match its use."
        case let .unsupportedSchema(version): return "Profile schema \(version) is not supported."
        }
    }
}
