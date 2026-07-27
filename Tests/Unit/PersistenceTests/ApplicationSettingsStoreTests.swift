import XCTest
import Foundation
@testable import Persistence
import RDPDomain

final class ApplicationSettingsStoreTests: XCTestCase {
    func testSettingsRoundTripAndRestore() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "RemoteDesktopTests.\(UUID().uuidString)"))
        let store = ApplicationSettingsStore(defaults: suite)
        let settings = ApplicationSettings(
            automaticReconnectEnabled: false,
            defaultReconnectAttempts: 7,
            defaultScaleMode: .actualSize,
            defaultRedirectionPreset: .standard
        )

        try store.save(settings)
        XCTAssertEqual(store.load(), settings)
        store.restoreDefaults()
        XCTAssertEqual(store.load(), ApplicationSettings())
    }

    func testUnsupportedSettingsSchemaFallsBackToDefaults() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "RemoteDesktopTests.\(UUID().uuidString)"))
        let store = ApplicationSettingsStore(defaults: suite)
        let invalid = ApplicationSettings(schemaVersion: 0, automaticReconnectEnabled: false)
        suite.set(try JSONEncoder().encode(invalid), forKey: "application-settings-v1")

        XCTAssertEqual(store.load(), ApplicationSettings())
    }

    func testManagedValuesParseKnownTypesAndIgnoreInvalidValues() {
        let policy = EnterprisePolicy(managedValues: [
            EnterprisePolicy.Key.automaticReconnectEnabled: false,
            EnterprisePolicy.Key.maximumReconnectAttempts: 2,
            EnterprisePolicy.Key.forcedScaleMode: "actualSize",
            EnterprisePolicy.Key.maximumRedirectionPreset: "standard",
            EnterprisePolicy.Key.allowCredentialSaving: false,
            EnterprisePolicy.Key.allowPrivateDiagnosticExport: false
        ])

        XCTAssertEqual(policy.automaticReconnectEnabled, false)
        XCTAssertEqual(policy.maximumReconnectAttempts, 2)
        XCTAssertEqual(policy.forcedScaleMode, .actualSize)
        XCTAssertEqual(policy.maximumRedirectionPreset, .standard)
        XCTAssertFalse(policy.allowsCredentialSaving)
        XCTAssertFalse(policy.allowsPrivateDiagnosticExport)

        let invalid = EnterprisePolicy(managedValues: [
            EnterprisePolicy.Key.maximumReconnectAttempts: 999,
            EnterprisePolicy.Key.forcedScaleMode: "unknown",
            EnterprisePolicy.Key.maximumRedirectionPreset: "unknown"
        ])
        XCTAssertNil(invalid.maximumReconnectAttempts)
        XCTAssertNil(invalid.forcedScaleMode)
        XCTAssertNil(invalid.maximumRedirectionPreset)

        let wrongNumericTypes = EnterprisePolicy(managedValues: [
            EnterprisePolicy.Key.maximumReconnectAttempts: true
        ])
        XCTAssertNil(wrongNumericTypes.maximumReconnectAttempts)
        XCTAssertNil(EnterprisePolicy(managedValues: [
            EnterprisePolicy.Key.maximumReconnectAttempts: 2.5
        ]).maximumReconnectAttempts)
        XCTAssertNil(EnterprisePolicy(managedValues: [
            EnterprisePolicy.Key.automaticReconnectEnabled: NSNumber(value: 1)
        ]).automaticReconnectEnabled)
    }

    func testSettingsStoreAppliesManagedLimitsOnLoadAndSave() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "RemoteDesktopTests.\(UUID().uuidString)"))
        let policy = EnterprisePolicy(
            automaticReconnectEnabled: false,
            maximumReconnectAttempts: 2,
            forcedScaleMode: .fit,
            maximumRedirectionPreset: .standard
        )
        let store = ApplicationSettingsStore(defaults: suite, policy: policy)

        try store.save(ApplicationSettings(
            automaticReconnectEnabled: true,
            defaultReconnectAttempts: 8,
            defaultScaleMode: .dynamicResolution,
            defaultRedirectionPreset: .complete
        ))

        XCTAssertEqual(store.load(), ApplicationSettings(
            automaticReconnectEnabled: false,
            defaultReconnectAttempts: 2,
            defaultScaleMode: .fit,
            defaultRedirectionPreset: .standard
        ))
        let storedData = try XCTUnwrap(suite.data(forKey: "application-settings-v1"))
        let stored = try JSONDecoder().decode(ApplicationSettings.self, from: storedData)
        XCTAssertTrue(stored.automaticReconnectEnabled)
        XCTAssertEqual(stored.defaultReconnectAttempts, 8)
        XCTAssertEqual(stored.defaultScaleMode, .dynamicResolution)
        XCTAssertEqual(stored.defaultRedirectionPreset, .complete)
        XCTAssertEqual(store.loadStored(), stored)
    }

    func testPolicyConstrictsProfileResourcesAndStoredReferences() {
        let targetReference = CredentialReference(kind: .target)
        let proxyReference = CredentialReference(kind: .proxy)
        let policy = EnterprisePolicy(
            maximumReconnectAttempts: 1,
            forcedScaleMode: .actualSize,
            maximumRedirectionPreset: .secure,
            allowsCredentialSaving: false
        )
        let profile = ConnectionProfile(
            name: "Managed",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            credentialReference: targetReference,
            route: .socks5(ProxyConfiguration(
                endpoint: Endpoint(host: "proxy.example", port: 1080),
                credentialReference: proxyReference
            )),
            display: DisplayConfiguration(scaleMode: .dynamicResolution),
            redirection: RedirectionPolicy.defaults(for: .complete),
            reconnect: ReconnectPolicy(maximumAttempts: 9)
        )

        let effective = policy.applying(to: profile)

        XCTAssertEqual(effective.reconnect.maximumAttempts, 1)
        XCTAssertEqual(effective.display.scaleMode, .actualSize)
        XCTAssertEqual(effective.redirection.preset, .secure)
        XCTAssertFalse(effective.redirection.clipboardImages)
        XCTAssertFalse(effective.redirection.microphone)
        XCTAssertFalse(effective.redirection.printers)
        XCTAssertTrue(effective.credentialReferences.isEmpty)
    }

    func testStoragePolicyPreservesTemporaryManagedLimitsButRemovesCredentials() {
        let targetReference = CredentialReference(kind: .target)
        let original = ConnectionProfile(
            name: "Managed",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            credentialReference: targetReference,
            display: DisplayConfiguration(scaleMode: .dynamicResolution),
            redirection: RedirectionPolicy.defaults(for: .complete),
            reconnect: ReconnectPolicy(maximumAttempts: 9)
        )
        var proposed = original
        proposed.display.scaleMode = .fit
        proposed.redirection = RedirectionPolicy.defaults(for: .secure)
        proposed.reconnect.maximumAttempts = 1
        let policy = EnterprisePolicy(
            maximumReconnectAttempts: 1,
            forcedScaleMode: .fit,
            maximumRedirectionPreset: .secure,
            allowsCredentialSaving: false
        )

        let stored = policy.applyingForStorage(to: proposed, preserving: original)

        XCTAssertEqual(stored.display.scaleMode, .dynamicResolution)
        XCTAssertEqual(stored.reconnect.maximumAttempts, 9)
        XCTAssertEqual(stored.redirection.preset, .complete)
        XCTAssertTrue(stored.redirection.clipboardImages)
        XCTAssertTrue(stored.redirection.microphone)
        XCTAssertTrue(stored.credentialReferences.isEmpty)

        var stricter = proposed
        stricter.reconnect.maximumAttempts = 0
        stricter.redirection = RedirectionPolicy.defaults(for: .secure)
        let stricterStored = policy.applyingForStorage(
            to: stricter,
            preserving: original,
            managedFieldChanges: [.reconnect, .redirection]
        )
        XCTAssertEqual(stricterStored.reconnect.maximumAttempts, 0)
        XCTAssertEqual(stricterStored.redirection.preset, .complete)
        XCTAssertFalse(stricterStored.redirection.clipboardImages)
        XCTAssertTrue(stricterStored.redirection.microphone)

        let newProfile = policy.applyingForStorage(to: original, preserving: nil)
        XCTAssertEqual(newProfile.reconnect.maximumAttempts, 1)
        XCTAssertEqual(newProfile.display.scaleMode, .fit)
        XCTAssertEqual(newProfile.redirection.preset, .secure)
        XCTAssertFalse(newProfile.redirection.microphone)
    }

    func testStoragePolicyOnlyPersistsRedirectionFieldsAllowedByCurrentPolicy() {
        let bookmark = SharedFolderBookmark(displayName: "Projects", bookmarkData: Data([1, 2, 3]))
        let original = ConnectionProfile(
            name: "Managed",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            redirection: RedirectionPolicy(
                preset: .complete,
                clipboardText: true,
                clipboardImages: true,
                clipboardFiles: true,
                audioPlayback: true,
                microphone: true,
                sharedFolders: [bookmark],
                printers: true,
                cameras: true,
                smartCards: true
            )
        )
        var proposed = original
        proposed.redirection.preset = .secure
        proposed.redirection.clipboardText = false
        proposed.redirection.clipboardImages = false
        proposed.redirection.clipboardFiles = false
        proposed.redirection.microphone = false
        proposed.redirection.sharedFolders = []
        proposed.redirection.printers = false
        proposed.redirection.cameras = false
        proposed.redirection.smartCards = false
        let policy = EnterprisePolicy(maximumRedirectionPreset: .secure)

        let stored = policy.applyingForStorage(
            to: proposed,
            preserving: original,
            managedFieldChanges: [.redirection]
        )

        XCTAssertEqual(stored.redirection.preset, .complete)
        XCTAssertFalse(stored.redirection.clipboardText)
        XCTAssertTrue(stored.redirection.clipboardImages)
        XCTAssertTrue(stored.redirection.clipboardFiles)
        XCTAssertTrue(stored.redirection.microphone)
        XCTAssertEqual(stored.redirection.sharedFolders, [bookmark])
        XCTAssertTrue(stored.redirection.printers)
        XCTAssertTrue(stored.redirection.cameras)
        XCTAssertTrue(stored.redirection.smartCards)
    }

    func testStoragePolicyAllowsAnExplicitPresetBelowTheManagedMaximum() {
        let original = ConnectionProfile(
            name: "Managed",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            redirection: RedirectionPolicy.defaults(for: .complete)
        )
        var proposed = original
        proposed.redirection = RedirectionPolicy.defaults(for: .secure)
        let policy = EnterprisePolicy(maximumRedirectionPreset: .standard)

        let stored = policy.applyingForStorage(
            to: proposed,
            preserving: original,
            managedFieldChanges: [.redirection]
        )

        XCTAssertEqual(stored.redirection.preset, .secure)
    }
}
