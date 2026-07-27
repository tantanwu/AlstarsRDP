import Foundation
import RDPDomain

public enum DiagnosticLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public enum DiagnosticCategory: String, Codable, Sendable {
    case application
    case persistence
    case transport
    case proxy
    case gateway
    case security
    case rdp
    case renderer
    case redirection
    case update
}

public enum DiagnosticValue: Codable, Equatable, Sendable {
    case publicText(String)
    case privateText(String)
    case number(Double)
    case boolean(Bool)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case publicText, privateText, number, boolean }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .publicText: self = .publicText(try container.decode(String.self, forKey: .value))
        case .privateText: self = .privateText(try container.decode(String.self, forKey: .value))
        case .number: self = .number(try container.decode(Double.self, forKey: .value))
        case .boolean: self = .boolean(try container.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .publicText(value):
            try container.encode(Kind.publicText, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .privateText(value):
            try container.encode(Kind.privateText, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .number(value):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct DiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var level: DiagnosticLevel
    public var category: DiagnosticCategory
    public var code: String
    public var message: String
    public var fields: [String: DiagnosticValue]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: DiagnosticLevel,
        category: DiagnosticCategory,
        code: String,
        message: String,
        fields: [String: DiagnosticValue] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.code = code
        self.message = message
        self.fields = fields
    }
}

public protocol DiagnosticRecording: Sendable {
    func record(_ event: DiagnosticEvent) async
}

public enum DiagnosticTimelineError: Error, LocalizedError, Equatable, Sendable {
    case exportTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case let .exportTooLarge(limit):
            return "The diagnostic export exceeds the \(limit)-byte safety limit. Clear older events and try again."
        }
    }
}

public actor DiagnosticTimeline: DiagnosticRecording {
    public static let maximumCapacity = 10_000
    public static let maximumCodeBytes = 128
    public static let maximumMessageBytes = 2 * 1024
    public static let maximumFieldCount = 32
    public static let maximumFieldNameBytes = 128
    public static let maximumTextValueBytes = 4 * 1024
    public static let maximumEventTextBytes = 8 * 1024
    public static let maximumExportBytes = 32 * 1024 * 1024

    private var events: [DiagnosticEvent] = []
    private let capacity: Int
    private let exportLimit: Int

    public init(capacity: Int = 2_000, maximumExportBytes: Int = 32 * 1024 * 1024) {
        self.capacity = min(Self.maximumCapacity, max(100, capacity))
        exportLimit = min(Self.maximumExportBytes, max(1_024, maximumExportBytes))
    }

    public func record(_ event: DiagnosticEvent) {
        if !Redactor.validateFieldNames(event.fields) {
            events.append(Self.rejectedEvent(
                timestamp: event.timestamp,
                code: "DIAGNOSTIC_FIELDS_REJECTED",
                message: "A diagnostic event was rejected because it used a forbidden or invalid field name."
            ))
        } else if Self.isWithinLimits(event) {
            events.append(event)
        } else {
            events.append(Self.rejectedEvent(
                timestamp: event.timestamp,
                code: "DIAGNOSTIC_EVENT_REJECTED",
                message: "A diagnostic event was rejected because it exceeded a safety limit."
            ))
        }
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }

    public func snapshot() -> [DiagnosticEvent] { events }

    public func removeAll() { events.removeAll(keepingCapacity: true) }

    public func export(includePrivateNetworkData: Bool = false) throws -> Data {
        let sanitized = events.map { event -> DiagnosticEvent in
            var copy = event
            copy.fields = event.fields.mapValues { value in
                switch value {
                case let .privateText(text):
                    return .privateText(includePrivateNetworkData ? text : Redactor.stableToken(for: text))
                default:
                    return value
                }
            }
            return copy
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sanitized)
        guard data.count <= exportLimit else {
            throw DiagnosticTimelineError.exportTooLarge(exportLimit)
        }
        return data
    }

    private static func isWithinLimits(_ event: DiagnosticEvent) -> Bool {
        guard !event.code.isEmpty,
              event.code.utf8.count <= maximumCodeBytes,
              event.message.utf8.count <= maximumMessageBytes,
              event.fields.count <= maximumFieldCount,
              !event.code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        var textBytes = event.code.utf8.count + event.message.utf8.count
        for (key, value) in event.fields {
            textBytes += key.utf8.count
            switch value {
            case let .publicText(text), let .privateText(text):
                guard text.utf8.count <= maximumTextValueBytes else { return false }
                textBytes += text.utf8.count
            case let .number(number):
                guard number.isFinite else { return false }
            case .boolean:
                break
            }
            guard textBytes <= maximumEventTextBytes else { return false }
        }
        return true
    }

    private static func rejectedEvent(timestamp: Date, code: String, message: String) -> DiagnosticEvent {
        DiagnosticEvent(
            timestamp: timestamp,
            level: .error,
            category: .security,
            code: code,
            message: message
        )
    }
}
