import CryptoKit
import Foundation

public enum Redactor {
    private static let forbiddenKeyFragments = [
        "password", "authorization", "credential", "token", "secret",
        "clipboard", "frame", "filecontent", "keychain"
    ]

    public static func stableToken(for value: String) -> String {
        var hasher = SHA256()
        var chunk: [UInt8] = []
        chunk.reserveCapacity(4 * 1024)
        for byte in value.utf8 {
            chunk.append(byte)
            if chunk.count == chunk.capacity {
                hasher.update(data: Data(chunk))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { hasher.update(data: Data(chunk)) }
        let digest = hasher.finalize()
        let prefix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "<private:\(prefix)>"
    }

    public static func validateFieldNames(_ fields: [String: DiagnosticValue]) -> Bool {
        fields.keys.allSatisfy { key in
            let normalized = key.lowercased().unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map { String($0) }
                .joined()
            return !key.isEmpty &&
                key.utf8.count <= DiagnosticTimeline.maximumFieldNameBytes &&
                !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
                forbiddenKeyFragments.allSatisfy { !normalized.contains($0) }
        }
    }
}
