import XCTest
@testable import Persistence
import RDPDomain

final class ProfileDatabaseTests: XCTestCase {
    func testSaveSearchDeleteAndExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let profile = ConnectionProfile(
            name: "Build Server",
            target: TargetIdentity(endpoint: Endpoint(host: "build.internal", port: 3389)),
            isFavorite: true
        )
        try await database.save(profile)
        let searchResults = try await database.profiles(search: "Build")
        XCTAssertEqual(searchResults.map(\.id), [profile.id])
        let favorites = try await database.profiles(favoritesOnly: true)
        XCTAssertEqual(favorites.count, 1)
        let export = try await database.exportProfiles()
        XCTAssertFalse(String(data: export, encoding: .utf8)?.lowercased().contains("password") ?? true)
        let archive = try JSONDecoder.iso8601.decode(ProfileArchive.self, from: export)
        XCTAssertEqual(archive.schemaVersion, ProfileArchive.currentSchemaVersion)
        XCTAssertEqual(archive.profiles.map(\.id), [profile.id])
        try await database.delete(id: profile.id)
        let deleted = try await database.profile(id: profile.id)
        XCTAssertNil(deleted)
    }

    func testExportRemovesLocalFolderAuthorizationData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let localPath = "/Users/alice/Confidential"
        let profile = ConnectionProfile(
            name: "Local folder",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            credentialReference: CredentialReference(kind: .target),
            redirection: RedirectionPolicy(
                drivePaths: [localPath],
                sharedFolders: [SharedFolderBookmark(
                    displayName: "Confidential",
                    bookmarkData: Data(localPath.utf8)
                )]
            )
        )
        try await database.save(profile)

        let data = try await database.exportProfiles()
        let archive = try JSONDecoder.iso8601.decode(ProfileArchive.self, from: data)

        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(localPath))
        XCTAssertTrue(archive.profiles[0].redirection.drivePaths.isEmpty)
        XCTAssertTrue(archive.profiles[0].redirection.sharedFolders.isEmpty)
        XCTAssertTrue(archive.profiles[0].credentialReferences.isEmpty)
    }

    func testSearchTreatsWildcardCharactersLiterally() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let literalPercent = ConnectionProfile(
            name: "Percent % Host",
            target: TargetIdentity(endpoint: Endpoint(host: "percent.example", port: 3389))
        )
        let ordinary = ConnectionProfile(
            name: "Ordinary Host",
            target: TargetIdentity(endpoint: Endpoint(host: "ordinary.example", port: 3389))
        )
        try await database.save(literalPercent)
        try await database.save(ordinary)

        let results = try await database.profiles(search: "%")

        XCTAssertEqual(results.map(\.id), [literalPercent.id])
    }

    func testSearchMatchesTagsCaseInsensitively() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let tagged = ConnectionProfile(
            name: "Production Server",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            tags: ["Finance-Team"]
        )
        let untagged = ConnectionProfile(
            name: "Development Server",
            target: TargetIdentity(endpoint: Endpoint(host: "dev.example", port: 3389))
        )
        try await database.save(tagged)
        try await database.save(untagged)

        let results = try await database.profiles(search: "finance")

        XCTAssertEqual(results.map(\.id), [tagged.id])
    }

    func testMarkConnectedPreservesCurrentProfileFields() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let profileUpdatedAt = Date(timeIntervalSince1970: 2_000)
        var profile = ConnectionProfile(
            name: "Original",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            updatedAt: profileUpdatedAt
        )
        try await database.save(profile)
        profile.name = "Edited"
        try await database.save(profile)
        let connectedAt = Date(timeIntervalSince1970: 1234)

        try await database.markConnected(id: profile.id, at: connectedAt)
        let loaded = try await database.profile(id: profile.id)
        let stored = try XCTUnwrap(loaded)

        XCTAssertEqual(stored.name, "Edited")
        XCTAssertEqual(stored.lastConnectedAt, connectedAt)
        XCTAssertEqual(stored.updatedAt, profileUpdatedAt)
    }

    func testMarkConnectedNeverRegressesLatestConnectionDate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let latestConnection = Date(timeIntervalSince1970: 3_000)
        let profile = ConnectionProfile(
            name: "Server",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            updatedAt: latestConnection,
            lastConnectedAt: latestConnection
        )
        try await database.save(profile)

        try await database.markConnected(id: profile.id, at: Date(timeIntervalSince1970: 1_000))

        let loaded = try await database.profile(id: profile.id)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.lastConnectedAt, latestConnection)
        XCTAssertEqual(stored.updatedAt, latestConnection)
    }

    func testRejectsCredentialReferenceSharedAcrossProfiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let reference = CredentialReference(kind: .target)
        let first = ConnectionProfile(
            name: "First",
            target: TargetIdentity(endpoint: Endpoint(host: "first.example", port: 3389)),
            credentialReference: reference
        )
        let second = ConnectionProfile(
            name: "Second",
            target: TargetIdentity(endpoint: Endpoint(host: "second.example", port: 3389)),
            credentialReference: reference
        )
        try await database.save(first)

        do {
            try await database.save(second)
            XCTFail("Expected credential ownership conflict")
        } catch let error as ProfileDatabaseError {
            guard case let .duplicateCredentialReference(conflict) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(conflict, reference)
        }
        let storedProfiles = try await database.profiles()
        XCTAssertEqual(storedProfiles.map(\.id), [first.id])
    }

    func testImportStripsCredentialReferencesFromEveryProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let reference = CredentialReference(kind: .target)
        let profiles = [
            ConnectionProfile(
                name: "First",
                target: TargetIdentity(endpoint: Endpoint(host: "first.example", port: 3389)),
                credentialReference: reference
            ),
            ConnectionProfile(
                name: "Second",
                target: TargetIdentity(endpoint: Endpoint(host: "second.example", port: 3389)),
                credentialReference: reference
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = try encoder.encode(ProfileArchive(profiles: profiles))

        let imported = try await database.importProfiles(from: archive)
        let storedProfiles = try await database.profiles()
        XCTAssertEqual(imported, 2)
        XCTAssertEqual(storedProfiles.count, 2)
        XCTAssertTrue(storedProfiles.allSatisfy { $0.credentialReferences.isEmpty })
    }

    func testImportReturnsCredentialReferencesMadeUnreachableByReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let reference = CredentialReference(kind: .target)
        let existing = ConnectionProfile(
            name: "Existing",
            target: TargetIdentity(endpoint: Endpoint(host: "old.example", port: 3389)),
            credentialReference: reference
        )
        try await database.save(existing)
        let replacement = ConnectionProfile(
            id: existing.id,
            name: "Replacement",
            target: TargetIdentity(endpoint: Endpoint(host: "new.example", port: 3389))
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = try encoder.encode(ProfileArchive(profiles: [replacement]))

        let result = try await database
            .importProfilesAndReturnUnreferencedCredentialReferences(from: archive)

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.unreferencedCredentialReferences, Set([reference]))
    }

    func testProfileReplacementReturnsOnlyUnreferencedCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let oldReference = CredentialReference(kind: .target)
        let newReference = CredentialReference(kind: .target)
        var profile = ConnectionProfile(
            name: "Server",
            target: TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389)),
            credentialReference: oldReference
        )
        try await database.save(profile)
        profile.credentialReference = newReference

        let cleanup = try await database.saveAndReturnUnreferencedCredentialReferences(
            profile,
            expectedToExist: true,
            expectedUpdatedAt: profile.updatedAt,
            cleanupCandidates: Set([oldReference])
        )

        XCTAssertEqual(cleanup, Set([oldReference]))
        let storedProfile = try await database.profile(id: profile.id)
        XCTAssertEqual(storedProfile?.credentialReference, newReference)
    }

    func testUpdateAfterDeletionDoesNotRecreateProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let profile = ConnectionProfile(
            name: "Deleted",
            target: TargetIdentity(endpoint: Endpoint(host: "deleted.example", port: 3389))
        )

        do {
            _ = try await database.saveAndReturnUnreferencedCredentialReferences(
                profile,
                expectedToExist: true,
                expectedUpdatedAt: nil,
                cleanupCandidates: Set()
            )
            XCTFail("Expected missing profile failure")
        } catch let error as ProfileDatabaseError {
            guard case let .profileNotFound(id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(id, profile.id)
        }
        let storedProfile = try await database.profile(id: profile.id)
        XCTAssertNil(storedProfile)
    }

    func testSaveRejectsAStaleProfileRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        var profile = ConnectionProfile(
            name: "Current",
            target: TargetIdentity(endpoint: Endpoint(host: "current.example", port: 3389)),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        try await database.save(profile)
        let staleDate = Date(timeIntervalSince1970: 100)
        profile.name = "Stale overwrite"

        do {
            _ = try await database.saveAndReturnUnreferencedCredentialReferences(
                profile,
                expectedToExist: true,
                expectedUpdatedAt: staleDate,
                cleanupCandidates: Set()
            )
            XCTFail("Expected stale revision failure")
        } catch let error as ProfileDatabaseError {
            guard case let .staleProfile(id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(id, profile.id)
        }
        let storedProfile = try await database.profile(id: profile.id)
        XCTAssertEqual(storedProfile?.name, "Current")
    }

    func testDeleteReturnsCredentialReferencesNoLongerOwnedByProfiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let reference = CredentialReference(kind: .target)
        let profile = ConnectionProfile(
            name: "Deleted",
            target: TargetIdentity(endpoint: Endpoint(host: "deleted.example", port: 3389)),
            credentialReference: reference
        )
        try await database.save(profile)

        let cleanup = try await database.deleteAndReturnUnreferencedCredentialReferences(id: profile.id)

        XCTAssertEqual(cleanup, Set([reference]))
        let storedProfile = try await database.profile(id: profile.id)
        XCTAssertNil(storedProfile)
    }

    func testImportRollsBackAllProfilesWhenOneEntryIsInvalid() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let valid = ConnectionProfile(
            name: "Valid",
            target: TargetIdentity(endpoint: Endpoint(host: "valid.example", port: 3389))
        )
        let invalid = ConnectionProfile(
            name: "",
            target: TargetIdentity(endpoint: Endpoint(host: "invalid.example", port: 3389))
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = try encoder.encode(ProfileArchive(profiles: [valid, invalid]))

        do {
            _ = try await database.importProfiles(from: archive)
            XCTFail("Expected import validation failure")
        } catch {
            let profiles = try await database.profiles()
            XCTAssertTrue(profiles.isEmpty)
        }
    }

    func testRejectsProfilePayloadAboveStorageLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let bookmarks = (0..<9).map { index in
            SharedFolderBookmark(
                displayName: "Large bookmark \(index)",
                bookmarkData: Data(repeating: UInt8(index), count: SharedFolderBookmark.maximumBookmarkBytes)
            )
        }
        let profile = ConnectionProfile(
            name: "Oversized",
            target: TargetIdentity(endpoint: Endpoint(host: "large.example", port: 3389)),
            redirection: RedirectionPolicy(sharedFolders: bookmarks)
        )

        do {
            try await database.save(profile)
            XCTFail("Expected payload limit failure")
        } catch let error as ProfileDatabaseError {
            guard case let .payloadTooLarge(limit) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(limit, ProfileDatabase.maximumProfilePayloadBytes)
        }
    }

    func testRejectsArchiveAboveImportLimitBeforeDecoding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let data = Data(repeating: 0, count: ProfileDatabase.maximumArchiveBytes + 1)

        do {
            _ = try await database.importProfiles(from: data)
            XCTFail("Expected archive limit failure")
        } catch let error as ProfileDatabaseError {
            guard case let .archiveTooLarge(limit) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(limit, ProfileDatabase.maximumArchiveBytes)
        }
    }

    func testRejectsArchiveWithDuplicateProfileIdentifiers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try ProfileDatabase(url: directory.appendingPathComponent("profiles.sqlite3"))
        let profile = ConnectionProfile(
            name: "Duplicate",
            target: TargetIdentity(endpoint: Endpoint(host: "duplicate.example", port: 3389))
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let archive = try encoder.encode(ProfileArchive(profiles: [profile, profile]))

        do {
            _ = try await database.importProfiles(from: archive)
            XCTFail("Expected duplicate identifier rejection")
        } catch let error as ProfileDatabaseError {
            guard case let .duplicateProfileIdentifier(id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(id, profile.id)
        }
        let profiles = try await database.profiles()
        XCTAssertTrue(profiles.isEmpty)
    }

    func testRollbackFailureDescriptionKeepsBothErrors() {
        let error = ProfileDatabaseError.rollback(
            original: "profile validation failed",
            rollback: "database is locked"
        )

        XCTAssertTrue(error.localizedDescription.contains("profile validation failed"))
        XCTAssertTrue(error.localizedDescription.contains("database is locked"))
    }

    func testQuarantineMovesDatabaseAndSidecarsTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("profiles.sqlite3")
        let sourceURLs = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
        for (index, url) in sourceURLs.enumerated() {
            try Data([UInt8(index)]).write(to: url)
        }

        let recovery = try XCTUnwrap(ProfileDatabase.quarantineStore(
            at: databaseURL,
            now: Date(timeIntervalSince1970: 0)
        ))

        XCTAssertTrue(recovery.lastPathComponent.contains("1970-01-01"))
        for source in sourceURLs {
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: recovery.appendingPathComponent(source.lastPathComponent).path
            ))
        }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
