import Foundation

public enum RDPFileError: Error, Equatable, LocalizedError, Sendable {
    case invalidEncoding
    case malformedLine(Int)
    case missingAddress
    case invalidAddress
    case invalidTextField(String)
    case containsSecret
    case fileTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "The RDP file is not valid UTF-8 or UTF-16 text."
        case let .malformedLine(line): return "The RDP file contains an invalid setting on line \(line)."
        case .missingAddress: return "The RDP file does not contain a full address."
        case .invalidAddress: return "The RDP file contains an invalid host or port."
        case let .invalidTextField(field): return "The RDP \(field) contains an unsupported control character."
        case .containsSecret: return "RDP files containing password data cannot be imported."
        case let .fileTooLarge(limit): return "The RDP file exceeds the \(limit)-byte import limit."
        }
    }
}

public enum RDPFileCodec {
    public static let maximumFileBytes = 1 * 1024 * 1024
    public static let maximumLineBytes = 16 * 1024
    public static let maximumSettingCount = 4_096

    public static func decode(contentsOf url: URL, suggestedName: String = "Imported Connection") throws -> ConnectionProfile {
        let data: Data
        do {
            data = try BoundedFileReader.read(from: url, maximumBytes: maximumFileBytes)
        } catch is BoundedFileReadError {
            throw RDPFileError.fileTooLarge(maximumFileBytes)
        }
        return try decode(data, suggestedName: suggestedName)
    }

    public static func decode(_ data: Data, suggestedName: String = "Imported Connection") throws -> ConnectionProfile {
        guard data.count <= maximumFileBytes else {
            throw RDPFileError.fileTooLarge(maximumFileBytes)
        }
        guard let text = decodeText(data) else { throw RDPFileError.invalidEncoding }
        var values: [String: (type: Character, value: String)] = [:]
        var settingCount = 0
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            guard rawLine.utf8.count <= maximumLineBytes else {
                throw RDPFileError.malformedLine(offset + 1)
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            settingCount += 1
            guard settingCount <= maximumSettingCount else {
                throw RDPFileError.malformedLine(offset + 1)
            }
            let components = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard components.count == 3, components[1].count == 1,
                  let type = components[1].first, type == "s" || type == "i" || type == "b" else {
                throw RDPFileError.malformedLine(offset + 1)
            }
            let key = components[0].trimmingCharacters(in: .whitespaces).lowercased()
            if containsSecret(key: key, type: type) {
                throw RDPFileError.containsSecret
            }
            values[key] = (type, String(components[2]))
        }
        guard let address = values["full address"]?.value, !address.isEmpty else { throw RDPFileError.missingAddress }
        let endpoint = try parseEndpoint(address)
        let width = uint32(values["desktopwidth"]?.value) ?? 1_920
        let height = uint32(values["desktopheight"]?.value) ?? 1_080
        let multimon = values["use multimon"]?.value == "1"
        let fullScreen = values["screen mode id"]?.value == "2"
        _ = fullScreen // The initial window mode is intentionally not persisted in schema v1.
        let clipboard = values["redirectclipboard"]?.value != "0"
        let audio = values["audiomode"]?.value != "2"

        return try ConnectionProfile(
            name: suggestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? endpoint.host : suggestedName,
            target: TargetIdentity(endpoint: endpoint),
            usernameHint: values["username"]?.value ?? "",
            domainHint: values["domain"]?.value ?? "",
            display: DisplayConfiguration(width: width, height: height, useAllDisplays: multimon),
            redirection: RedirectionPolicy(clipboardText: clipboard, clipboardImages: clipboard, audioPlayback: audio)
        ).validated()
    }

    public static func encode(_ profile: ConnectionProfile) throws -> Data {
        let profile = try profile.validated()
        try validateTextField(profile.usernameHint, field: "username")
        try validateTextField(profile.domainHint, field: "domain")
        let host = profile.target.endpoint.host.contains(":") ? "[\(profile.target.endpoint.host)]" : profile.target.endpoint.host
        let address = profile.target.endpoint.port == 3389 ? host : "\(host):\(profile.target.endpoint.port)"
        let values = [
            "full address:s:\(address)",
            "username:s:\(profile.usernameHint)",
            "domain:s:\(profile.domainHint)",
            "desktopwidth:i:\(profile.display.width)",
            "desktopheight:i:\(profile.display.height)",
            "use multimon:i:\(profile.display.useAllDisplays ? 1 : 0)",
            "redirectclipboard:i:\((profile.redirection.clipboardText || profile.redirection.clipboardImages) ? 1 : 0)",
            "audiomode:i:\(profile.redirection.audioPlayback ? 0 : 2)",
            "redirectdrives:i:0",
            "prompt for credentials:i:1",
            "authentication level:i:2",
            "enablecredsspsupport:i:1"
        ]
        guard let body = (values.joined(separator: "\r\n") + "\r\n").data(using: .utf16LittleEndian) else {
            throw RDPFileError.invalidEncoding
        }
        var data = Data([0xFF, 0xFE])
        data.append(body)
        return data
    }

    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        return String(data: data, encoding: .utf8)
    }

    private static func parseEndpoint(_ input: String) throws -> Endpoint {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let port: UInt16
        if trimmed.hasPrefix("[") {
            guard let closing = trimmed.firstIndex(of: "]") else { throw RDPFileError.invalidAddress }
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            let suffix = trimmed[trimmed.index(after: closing)...]
            if suffix.isEmpty { port = 3389 }
            else {
                guard suffix.first == ":", let parsed = UInt16(String(suffix.dropFirst())), parsed > 0 else { throw RDPFileError.invalidAddress }
                port = parsed
            }
        } else if trimmed.filter({ $0 == ":" }).count == 1, let separator = trimmed.lastIndex(of: ":") {
            host = String(trimmed[..<separator])
            guard let parsed = UInt16(String(trimmed[trimmed.index(after: separator)...])), parsed > 0 else { throw RDPFileError.invalidAddress }
            port = parsed
        } else {
            host = trimmed
            port = 3389
        }
        do { return try Endpoint(host: host, port: port).validated(field: "target") }
        catch { throw RDPFileError.invalidAddress }
    }

    private static func uint32(_ text: String?) -> UInt32? {
        text.flatMap(UInt32.init)
    }

    private static func validateTextField(_ value: String, field: String) throws {
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RDPFileError.invalidTextField(field)
        }
    }

    private static func containsSecret(key: String, type: Character) -> Bool {
        if type == "b" { return true }
        let safeCredentialMetadata = [
            "prompt for credentials",
            "promptcredentialonce",
            "gatewaycredentialssource"
        ]
        if safeCredentialMetadata.contains(key) { return false }

        let normalizedKey = key.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
        return ["password", "authorization", "credential", "token", "secret"]
            .contains { normalizedKey.contains($0) }
    }
}
