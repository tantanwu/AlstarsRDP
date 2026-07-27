import Foundation
import Network
import RDPDomain

public struct ProxyCredential: Equatable, Sendable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public enum ProxyProtocolError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedAuthentication
    case authenticationFailed
    case malformedResponse
    case responseTooLarge
    case connectionRejected(code: UInt8)
    case httpStatus(Int, String)
    case invalidCredential
    case invalidTarget
    case invalidHeaderValue

    public var errorDescription: String? {
        switch self {
        case .unsupportedAuthentication: return "The proxy does not support an offered authentication method."
        case .authenticationFailed: return "The proxy rejected the supplied credentials."
        case .malformedResponse: return "The proxy returned a malformed response."
        case .responseTooLarge: return "The proxy response exceeded the safety limit."
        case let .connectionRejected(code): return "The SOCKS5 proxy rejected the target (code \(code))."
        case let .httpStatus(code, reason): return "The HTTP proxy returned \(code) \(reason)."
        case .invalidCredential: return "The proxy username or password is too long."
        case .invalidTarget: return "The proxy target cannot be encoded."
        case .invalidHeaderValue: return "An HTTP proxy header value is invalid."
        }
    }
}

public enum SOCKS5Protocol {
    public static func greeting(usesCredentials: Bool) -> Data {
        Data(usesCredentials ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00])
    }

    public static func selectedAuthentication(from data: Data, expectedCredentials: Bool) throws -> UInt8 {
        guard data.count == 2, data[0] == 0x05 else { throw ProxyProtocolError.malformedResponse }
        let method = data[1]
        guard method != 0xff else { throw ProxyProtocolError.unsupportedAuthentication }
        if method == 0x02, !expectedCredentials { throw ProxyProtocolError.unsupportedAuthentication }
        guard method == 0x00 || method == 0x02 else { throw ProxyProtocolError.unsupportedAuthentication }
        return method
    }

    public static func usernamePasswordRequest(_ credential: ProxyCredential) throws -> Data {
        let usernameCount = credential.username.utf8.count
        let passwordCount = credential.password.utf8.count
        guard usernameCount > 0, usernameCount <= 255, passwordCount > 0, passwordCount <= 255 else {
            throw ProxyProtocolError.invalidCredential
        }
        let username = Data(credential.username.utf8)
        let password = Data(credential.password.utf8)
        var data = Data([0x01, UInt8(username.count)])
        data.append(username)
        data.append(UInt8(password.count))
        data.append(password)
        return data
    }

    public static func validateAuthenticationResponse(_ data: Data) throws {
        guard data.count == 2, data[0] == 0x01 else { throw ProxyProtocolError.malformedResponse }
        guard data[1] == 0x00 else { throw ProxyProtocolError.authenticationFailed }
    }

    public static func connectRequest(to target: Endpoint) throws -> Data {
        do { _ = try target.validated(field: "target") }
        catch { throw ProxyProtocolError.invalidTarget }

        var data = Data([0x05, 0x01, 0x00])
        if let address = IPv4Address(target.host) {
            data.append(0x01)
            data.append(address.rawValue)
        } else if let address = IPv6Address(target.host) {
            data.append(0x04)
            data.append(address.rawValue)
        } else {
            let host = Data(target.host.utf8)
            guard !host.isEmpty, host.count <= 255 else {
                throw ProxyProtocolError.invalidTarget
            }
            data.append(0x03)
            data.append(UInt8(host.count))
            data.append(host)
        }
        data.append(UInt8(target.port >> 8))
        data.append(UInt8(target.port & 0xff))
        return data
    }

    public static func replyLength(from prefix: Data) throws -> Int {
        guard prefix.count >= 5, prefix[0] == 0x05, prefix[2] == 0x00 else {
            throw ProxyProtocolError.malformedResponse
        }
        guard prefix[1] == 0x00 else { throw ProxyProtocolError.connectionRejected(code: prefix[1]) }
        switch prefix[3] {
        case 0x01: return 10
        case 0x04: return 22
        case 0x03:
            guard prefix[4] > 0 else { throw ProxyProtocolError.malformedResponse }
            return 7 + Int(prefix[4])
        default: throw ProxyProtocolError.malformedResponse
        }
    }
}

public struct HTTPConnectResponse: Equatable, Sendable {
    public var statusCode: Int
    public var reason: String
    public var headerLength: Int
}

public enum HTTPConnectProtocol {
    public static let maximumHeaderBytes = 16 * 1024
    public static let maximumRequestBytes = 16 * 1024

    public static func request(
        target: Endpoint,
        credential: ProxyCredential?,
        userAgent: String = "RemoteDesktop/0.1"
    ) throws -> Data {
        _ = try target.validated(field: "target")
        guard !userAgent.isEmpty,
              userAgent.utf8.count <= maximumRequestBytes,
              !userAgent.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ProxyProtocolError.invalidHeaderValue
        }
        let authority = target.host.contains(":") ? "[\(target.host)]:\(target.port)" : "\(target.host):\(target.port)"
        var lines = [
            "CONNECT \(authority) HTTP/1.1",
            "Host: \(authority)",
            "User-Agent: \(userAgent)",
            "Proxy-Connection: keep-alive"
        ]
        if let credential {
            let usernameBytes = credential.username.utf8.count
            let passwordBytes = credential.password.utf8.count
            guard usernameBytes > 0, passwordBytes > 0,
                  !credential.username.contains(":"),
                  !credential.username.unicodeScalars.contains(where: { $0.value == 0 }),
                  !credential.password.unicodeScalars.contains(where: { $0.value == 0 }),
                  !credential.username.contains(where: { $0.isNewline }),
                  !credential.password.contains(where: { $0.isNewline }),
                  usernameBytes < maximumRequestBytes,
                  passwordBytes <= maximumRequestBytes - usernameBytes - 1 else {
                throw ProxyProtocolError.invalidCredential
            }
            let token = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
            lines.append("Proxy-Authorization: Basic \(token)")
        }
        let request = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        guard request.count <= maximumRequestBytes else { throw ProxyProtocolError.invalidCredential }
        return request
    }

    public static func parseResponse(_ data: Data) throws -> HTTPConnectResponse? {
        let delimiter = Data([13, 10, 13, 10])
        guard let range = data.range(of: delimiter) else {
            guard data.count < maximumHeaderBytes else { throw ProxyProtocolError.responseTooLarge }
            return nil
        }
        guard range.upperBound <= maximumHeaderBytes else { throw ProxyProtocolError.responseTooLarge }
        guard let header = String(data: data[..<range.lowerBound], encoding: .isoLatin1) else {
            throw ProxyProtocolError.malformedResponse
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let status = lines.first else { throw ProxyProtocolError.malformedResponse }
        let parts = status.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              parts[0] == "HTTP/1.0" || parts[0] == "HTTP/1.1",
              parts[1].count == 3,
              parts[1].allSatisfy(\.isNumber),
              let code = Int(parts[1]),
              Self.isValidStatusLine(status),
              lines.dropFirst().allSatisfy(Self.isValidHeaderLine) else {
            throw ProxyProtocolError.malformedResponse
        }
        let reason = parts.count == 3 ? String(parts[2]) : ""
        guard (200..<300).contains(code) else { throw ProxyProtocolError.httpStatus(code, reason) }
        return HTTPConnectResponse(statusCode: code, reason: reason, headerLength: range.upperBound)
    }

    private static func isValidHeaderLine(_ line: String) -> Bool {
        guard !line.isEmpty, let separator = line.firstIndex(of: ":"), separator != line.startIndex else {
            return false
        }
        let name = line[..<separator]
        guard name.unicodeScalars.allSatisfy(Self.isHeaderNameScalar) else { return false }
        return !line[line.index(after: separator)...].unicodeScalars.contains { scalar in
            scalar.value == 0 || (scalar.value < 0x20 && scalar.value != 0x09) || scalar.value == 0x7f
        }
    }

    private static func isValidStatusLine(_ line: String) -> Bool {
        !line.unicodeScalars.contains { scalar in
            scalar.value == 0 || (scalar.value < 0x20 && scalar.value != 0x09) || scalar.value == 0x7f
        }
    }

    private static func isHeaderNameScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
            return true
        case 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }
}
