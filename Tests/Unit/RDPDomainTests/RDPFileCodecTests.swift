import XCTest
@testable import RDPDomain

final class RDPFileCodecTests: XCTestCase {
    func testImportsUTF8RDPFile() throws {
        let source = """
        full address:s:server.example.com:3390
        username:s:user@example.com
        desktopwidth:i:1440
        desktopheight:i:900
        redirectclipboard:i:0
        audiomode:i:2
        """
        let profile = try RDPFileCodec.decode(Data(source.utf8), suggestedName: "Imported")

        XCTAssertEqual(profile.target.endpoint, Endpoint(host: "server.example.com", port: 3390))
        XCTAssertEqual(profile.usernameHint, "user@example.com")
        XCTAssertEqual(profile.display.width, 1440)
        XCTAssertFalse(profile.redirection.clipboardText)
        XCTAssertFalse(profile.redirection.audioPlayback)
    }

    func testIPv6RoundTripNeverExportsCredentials() throws {
        let profile = ConnectionProfile(
            name: "IPv6",
            target: TargetIdentity(endpoint: Endpoint(host: "2001:db8::10", port: 3391)),
            usernameHint: "operator",
            credentialReference: CredentialReference(kind: .target)
        )
        let data = try RDPFileCodec.encode(profile)
        let decoded = try RDPFileCodec.decode(data, suggestedName: "IPv6")
        let text = try XCTUnwrap(String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian))

        XCTAssertEqual(decoded.target.endpoint, profile.target.endpoint)
        XCTAssertFalse(text.lowercased().contains("password"))
        XCTAssertNil(decoded.credentialReference)
    }

    func testRejectsPasswordBlob() {
        let source = "full address:s:server.example.com\npassword 51:b:01020304\n"
        XCTAssertThrowsError(try RDPFileCodec.decode(Data(source.utf8))) { error in
            XCTAssertEqual(error as? RDPFileError, .containsSecret)
        }
    }

    func testAllowsKnownNonSecretCredentialPromptMetadata() throws {
        let source = "full address:s:server.example.com\nprompt for credentials:i:1\n"

        let profile = try RDPFileCodec.decode(Data(source.utf8))

        XCTAssertEqual(profile.target.endpoint.host, "server.example.com")
    }

    func testRejectsUnknownCredentialAndAuthorizationFields() {
        for field in ["credential:s:secret", "proxy authorization:s:secret", "access token:s:secret"] {
            let source = "full address:s:server.example.com\n\(field)\n"
            XCTAssertThrowsError(try RDPFileCodec.decode(Data(source.utf8))) { error in
                XCTAssertEqual(error as? RDPFileError, .containsSecret)
            }
        }
    }

    func testRejectsSecretFieldNamesWithSeparators() {
        let fields = [
            "pass-word:s:secret",
            "proxy_authorization:s:secret",
            "access.token:s:secret",
            "client\u{2003}credential:s:secret"
        ]
        for field in fields {
            let source = "full address:s:server.example.com\n\(field)\n"
            XCTAssertThrowsError(try RDPFileCodec.decode(Data(source.utf8)), field) { error in
                XCTAssertEqual(error as? RDPFileError, .containsSecret)
            }
        }
    }

    func testRejectsOversizedRDPFileBeforeParsing() {
        let data = Data(repeating: 65, count: RDPFileCodec.maximumFileBytes + 1)

        XCTAssertThrowsError(try RDPFileCodec.decode(data)) { error in
            XCTAssertEqual(error as? RDPFileError, .fileTooLarge(RDPFileCodec.maximumFileBytes))
        }
    }

    func testFileImportStopsAtTheReadLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).rdp")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 65, count: RDPFileCodec.maximumFileBytes + 1).write(to: url)

        XCTAssertThrowsError(try RDPFileCodec.decode(contentsOf: url)) { error in
            XCTAssertEqual(error as? RDPFileError, .fileTooLarge(RDPFileCodec.maximumFileBytes))
        }
    }

    func testExportRejectsSettingInjectionInUsername() {
        let profile = ConnectionProfile(
            name: "Injected",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example.com", port: 3389)),
            usernameHint: "operator\r\nredirectdrives:i:1"
        )

        XCTAssertThrowsError(try RDPFileCodec.encode(profile)) { error in
            XCTAssertEqual(error as? RDPFileError, .invalidTextField("username"))
            XCTAssertEqual(error.localizedDescription, "The RDP username contains an unsupported control character.")
        }
    }

    func testRejectsOversizedSettingLine() {
        let line = "full address:s:" + String(repeating: "a", count: RDPFileCodec.maximumLineBytes)

        XCTAssertThrowsError(try RDPFileCodec.decode(Data(line.utf8))) { error in
            XCTAssertEqual(error as? RDPFileError, .malformedLine(1))
        }
    }

    func testRejectsExcessiveSettingCount() {
        let source = (0...RDPFileCodec.maximumSettingCount)
            .map { "unknown\($0):i:1" }
            .joined(separator: "\n")

        XCTAssertThrowsError(try RDPFileCodec.decode(Data(source.utf8))) { error in
            XCTAssertEqual(
                error as? RDPFileError,
                .malformedLine(RDPFileCodec.maximumSettingCount + 1)
            )
        }
    }
}
