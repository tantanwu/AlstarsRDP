import Foundation

public enum SessionErrorCategory: String, Codable, CaseIterable, Sendable {
    case local = "LOCAL"
    case dns = "DNS"
    case proxy = "PROXY"
    case gateway = "GATEWAY"
    case target = "TARGET"
    case tls = "TLS"
    case authentication = "AUTH"
    case rdp = "RDP"
    case session = "SESSION"
}

public struct SessionError: Error, Codable, Equatable, LocalizedError, Sendable {
    public var category: SessionErrorCategory
    public var code: String
    public var message: String
    public var recoverySuggestion: String?
    public var isRecoverable: Bool

    public init(
        category: SessionErrorCategory,
        code: String,
        message: String,
        recoverySuggestion: String? = nil,
        isRecoverable: Bool = false
    ) {
        self.category = category
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.isRecoverable = isRecoverable
    }

    public var errorDescription: String? { message }
}

