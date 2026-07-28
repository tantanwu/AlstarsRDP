import XCTest
@testable import RDPDomain

final class ConnectionProfileTests: XCTestCase {
    func testValidProfileRoundTripsWithoutASecretField() throws {
        let profile = ConnectionProfile(
            name: "Production",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example.com", port: 3389)),
            credentialReference: CredentialReference(kind: .target),
            route: .socks5(ProxyConfiguration(
                endpoint: Endpoint(host: "proxy.example.com", port: 1080),
                credentialReference: CredentialReference(kind: .proxy)
            ))
        )
        let validated = try profile.validated()
        let data = try JSONEncoder().encode(validated)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.lowercased().contains("password"))
        XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: data), validated)
    }

    func testRejectsWhitespaceInHost() {
        let profile = ConnectionProfile(
            name: "Invalid",
            target: TargetIdentity(endpoint: Endpoint(host: "bad host", port: 3389))
        )
        XCTAssertThrowsError(try profile.validated())
    }

    func testRejectsControlCharactersInHostAndCertificateName() {
        let invalidHost = ConnectionProfile(
            name: "Invalid host",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example.com\0suffix", port: 3389))
        )
        let invalidCertificate = ConnectionProfile(
            name: "Invalid certificate",
            target: TargetIdentity(
                endpoint: Endpoint(host: "server.example.com", port: 3389),
                certificateName: "server.example.com\nother.example.com"
            )
        )

        XCTAssertThrowsError(try invalidHost.validated())
        XCTAssertThrowsError(try invalidCertificate.validated())
    }

    func testRejectsUnsafeProfileTextAndExcessiveDesktopSize() {
        let invalidName = ConnectionProfile(
            name: "Invalid\nName",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389))
        )
        let invalidHint = ConnectionProfile(
            name: "Invalid hint",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            usernameHint: "user\0suffix"
        )
        let excessiveDesktop = ConnectionProfile(
            name: "Large desktop",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            display: DisplayConfiguration(width: 16_384, height: 16_384)
        )

        XCTAssertThrowsError(try invalidName.validated())
        XCTAssertThrowsError(try invalidHint.validated())
        XCTAssertThrowsError(try excessiveDesktop.validated())
    }

    func testRejectsInvalidReconnectDelayBounds() {
        let profile = ConnectionProfile(
            name: "Invalid reconnect",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            reconnect: ReconnectPolicy(
                maximumAttempts: 3,
                initialDelayMilliseconds: 50,
                maximumDelayMilliseconds: 10
            )
        )

        XCTAssertThrowsError(try profile.validated()) { error in
            XCTAssertEqual(error as? ProfileValidationError, .invalidReconnectPolicy)
        }
    }

    func testRejectsAuthorityDelimiterInHost() {
        let profile = ConnectionProfile(
            name: "Invalid authority",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example.com/path", port: 3389))
        )

        XCTAssertThrowsError(try profile.validated())
    }

    func testRouteValidationRejectsInvalidProxyWithoutAProfileSave() {
        let route = RouteConfiguration.socks5(ProxyConfiguration(
            endpoint: Endpoint(host: "bad proxy", port: 1080),
            usernameHint: "alice"
        ))

        XCTAssertThrowsError(try route.validated()) { error in
            XCTAssertEqual(error as? ProfileValidationError, .invalidHost("proxy"))
        }
    }

    func testRouteValidationRejectsUnimplementedLocalProxyDNSMode() {
        let route = RouteConfiguration.socks5(ProxyConfiguration(
            endpoint: Endpoint(host: "proxy.example", port: 1080),
            resolvesTargetName: false
        ))

        XCTAssertThrowsError(try route.validated()) { error in
            XCTAssertEqual(
                error as? ProfileValidationError,
                .unsupportedProxyNameResolution
            )
        }
    }

    func testSecureRedirectionDefaultsKeepSensitiveDevicesOff() {
        let policy = RedirectionPolicy.secure
        XCTAssertFalse(policy.microphone)
        XCTAssertFalse(policy.clipboardImages)
        XCTAssertFalse(policy.clipboardFiles)
        XCTAssertTrue(policy.drivePaths.isEmpty)
        XCTAssertFalse(policy.printers)
        XCTAssertFalse(policy.cameras)
        XCTAssertFalse(policy.smartCards)
    }

    func testLegacyRedirectionPolicyDecodesWithoutBookmarks() throws {
        let data = Data(#"{"preset":"secure","clipboardText":true,"clipboardImages":true,"clipboardFiles":false,"audioPlayback":true,"microphone":false,"drivePaths":[],"printers":false,"cameras":false,"smartCards":false}"#.utf8)
        let policy = try JSONDecoder().decode(RedirectionPolicy.self, from: data)

        XCTAssertTrue(policy.sharedFolders.isEmpty)
    }

    func testLegacyDrivePathsAreDecodedButNeverReExported() throws {
        let legacyPath = "/Users/alice/Confidential"
        let data = Data(#"{"preset":"complete","drivePaths":["/Users/alice/Confidential"]}"#.utf8)
        let policy = try JSONDecoder().decode(RedirectionPolicy.self, from: data)

        XCTAssertEqual(policy.drivePaths, [legacyPath])
        let exported = try JSONEncoder().encode(policy)
        let json = try XCTUnwrap(String(data: exported, encoding: .utf8))
        XCTAssertFalse(json.contains(legacyPath))
        XCTAssertFalse(json.contains("drivePaths"))
        XCTAssertTrue(try JSONDecoder().decode(RedirectionPolicy.self, from: exported).drivePaths.isEmpty)
    }

    func testLegacyProxyConfigurationDecodesWithoutUsernameHint() throws {
        let data = Data(#"{"endpoint":{"host":"proxy.example","port":1080},"resolvesTargetName":true}"#.utf8)
        let proxy = try JSONDecoder().decode(ProxyConfiguration.self, from: data)

        XCTAssertEqual(proxy.usernameHint, "")
        XCTAssertNil(proxy.credentialReference)
        XCTAssertTrue(proxy.resolvesTargetName)
        XCTAssertFalse(proxy.expectsCredentials)
    }

    func testProxyCredentialExpectationSurvivesMissingKeychainItem() {
        let referenceOnly = ProxyConfiguration(
            endpoint: Endpoint(host: "proxy.example", port: 1080),
            credentialReference: CredentialReference(kind: .proxy)
        )
        let usernameOnly = ProxyConfiguration(
            endpoint: Endpoint(host: "proxy.example", port: 1080),
            usernameHint: "alice"
        )
        let anonymous = ProxyConfiguration(endpoint: Endpoint(host: "proxy.example", port: 1080))

        XCTAssertTrue(referenceOnly.expectsCredentials)
        XCTAssertTrue(usernameOnly.expectsCredentials)
        XCTAssertFalse(anonymous.expectsCredentials)
    }

    func testProfileCollectsTargetAndRouteCredentialReferences() {
        let target = CredentialReference(kind: .target)
        let proxy = CredentialReference(kind: .proxy)
        let profile = ConnectionProfile(
            name: "Test",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            credentialReference: target,
            route: .socks5(ProxyConfiguration(
                endpoint: Endpoint(host: "proxy.example", port: 1080),
                credentialReference: proxy
            ))
        )

        XCTAssertEqual(profile.credentialReferences, [target, proxy])
    }

    func testSharedFolderBookmarkRoundTripsWithoutPlainPath() throws {
        let policy = RedirectionPolicy(
            drivePaths: [],
            sharedFolders: [SharedFolderBookmark(displayName: "Work", bookmarkData: Data([1, 2, 3]))]
        )
        let data = try JSONEncoder().encode(policy)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("/Users/example/Work"))
        XCTAssertEqual(try JSONDecoder().decode(RedirectionPolicy.self, from: data), policy)
    }

    func testRejectsInvalidSharedFolderBookmarkMetadata() {
        let emptyBookmark = ConnectionProfile(
            name: "Shared folder",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            redirection: RedirectionPolicy(sharedFolders: [
                SharedFolderBookmark(displayName: "Work", bookmarkData: Data())
            ])
        )
        let injectedName = ConnectionProfile(
            name: "Shared folder",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            redirection: RedirectionPolicy(sharedFolders: [
                SharedFolderBookmark(displayName: "Work\nOther", bookmarkData: Data([1]))
            ])
        )

        XCTAssertThrowsError(try emptyBookmark.validated()) { error in
            XCTAssertEqual(error as? ProfileValidationError, .invalidSharedFolders)
        }
        XCTAssertThrowsError(try injectedName.validated()) { error in
            XCTAssertEqual(error as? ProfileValidationError, .invalidSharedFolders)
        }
    }

    func testAuthenticationFailuresNeverRetry() {
        XCTAssertEqual(RDPFailureClassifier.disposition(for: 0x0002_0009), .authentication)
        XCTAssertEqual(RDPFailureClassifier.disposition(for: 0x0002_0011), .authentication)
        XCTAssertEqual(RDPFailureClassifier.disposition(for: 0x0002_0018), .authentication)
        XCTAssertEqual(RDPFailureClassifier.disposition(for: 0x0002_000D), .retryable)
        XCTAssertEqual(RDPFailureClassifier.disposition(for: 0x0002_001D), .retryable)
        XCTAssertEqual(RDPFailureClassifier.disposition(for: 0xDEAD_BEEF), .terminal)
    }

    func testConnectionFailureSummariesIdentifyTheFailureStage() {
        XCTAssertEqual(
            RDPFailureClassifier.summary(for: 0x0002_0001),
            "The RDP client components could not be initialized."
        )
        XCTAssertEqual(
            RDPFailureClassifier.summary(for: 0x0002_0005),
            "The target computer name could not be resolved."
        )
        XCTAssertEqual(
            RDPFailureClassifier.summary(for: 0x0002_0008),
            "TLS or RDP security negotiation failed."
        )
        XCTAssertEqual(
            RDPFailureClassifier.summary(for: 0x0002_0015),
            "Windows authentication failed or the account cannot sign in remotely."
        )
        XCTAssertEqual(RDPFailureClassifier.summary(for: 0xDEAD_BEEF), "The RDP connection failed.")
    }

    func testReconnectBackoffIsBounded() {
        let policy = ReconnectPolicy(maximumAttempts: 8, initialDelayMilliseconds: 1_000, maximumDelayMilliseconds: 5_000)
        XCTAssertEqual(ReconnectBackoff.delayMilliseconds(forAttempt: 1, policy: policy), 1_000)
        XCTAssertEqual(ReconnectBackoff.delayMilliseconds(forAttempt: 2, policy: policy), 2_000)
        XCTAssertEqual(ReconnectBackoff.delayMilliseconds(forAttempt: 8, policy: policy), 5_000)
    }
}
