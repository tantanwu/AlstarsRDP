import Diagnostics
import Foundation
import RDPDomain
import SQLite3

public enum ProfileDatabaseError: Error, LocalizedError, Sendable {
    case open(String)
    case prepare(String)
    case execute(String)
    case decode(UUID, String)
    case unsupportedSchema(Int)
    case payloadTooLarge(Int)
    case archiveTooLarge(Int)
    case storageTooLarge(Int)
    case tooManyProfiles(Int)
    case duplicateProfileIdentifier(UUID)
    case duplicateCredentialReference(CredentialReference)
    case profileNotFound(UUID)
    case staleProfile(UUID)
    case rollback(original: String, rollback: String)
    case recoveryRollback(original: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case let .open(message): return "Could not open the profile database: \(message)"
        case let .prepare(message): return "Could not prepare a database operation: \(message)"
        case let .execute(message): return "Could not update the profile database: \(message)"
        case let .decode(id, message): return "Profile \(id) is damaged: \(message)"
        case let .unsupportedSchema(version): return "Database schema \(version) is not supported by this application."
        case let .payloadTooLarge(limit): return "A connection profile exceeds the \(limit)-byte storage limit."
        case let .archiveTooLarge(limit): return "The connection archive exceeds the \(limit)-byte import limit."
        case let .storageTooLarge(limit): return "The profile database exceeds the \(limit)-byte payload limit."
        case let .tooManyProfiles(limit): return "The profile database cannot contain more than \(limit) connections."
        case let .duplicateProfileIdentifier(id): return "The connection archive contains profile \(id) more than once."
        case .duplicateCredentialReference:
            return "A Keychain credential reference is assigned to more than one connection profile."
        case let .profileNotFound(id): return "Connection profile \(id) no longer exists."
        case let .staleProfile(id):
            return "Connection profile \(id) changed while credentials were being saved. Review the current settings and try again."
        case let .rollback(original, rollback):
            return "The database operation failed (\(original)), and its rollback also failed (\(rollback))."
        case let .recoveryRollback(original, rollback):
            return "The damaged database could not be isolated (\(original)), and recovery rollback also failed (\(rollback))."
        }
    }
}

public struct ProfileArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var exportedAt: Date
    public var profiles: [ConnectionProfile]

    public init(schemaVersion: Int = currentSchemaVersion, exportedAt: Date = Date(), profiles: [ConnectionProfile]) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.profiles = profiles
    }
}

public struct ProfileImportResult: Equatable, Sendable {
    public var importedCount: Int
    public var unreferencedCredentialReferences: Set<CredentialReference>

    public init(
        importedCount: Int,
        unreferencedCredentialReferences: Set<CredentialReference>
    ) {
        self.importedCount = importedCount
        self.unreferencedCredentialReferences = unreferencedCredentialReferences
    }
}

public actor ProfileDatabase {
    public static let currentSchemaVersion = 1
    public static let maximumProfilePayloadBytes = 8 * 1024 * 1024
    public static let maximumArchiveBytes = 64 * 1024 * 1024
    public static let maximumTotalProfilePayloadBytes = 256 * 1024 * 1024
    public static let maximumProfileCount = 10_000

    private var db: OpaquePointer?
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) throws {
        self.url = url
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw ProfileDatabaseError.open(message)
        }
        db = handle
        do { try Self.migrate(handle) }
        catch { sqlite3_close(handle); db = nil; throw error }
    }

    deinit { if let db { sqlite3_close(db) } }

    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return support.appendingPathComponent("RemoteDesktop", isDirectory: true)
            .appendingPathComponent("profiles.sqlite3", isDirectory: false)
    }

    /// Moves the database and SQLite sidecars into a dated recovery directory.
    /// Callers must obtain explicit user confirmation before invoking this.
    @discardableResult
    public static func quarantineStore(at url: URL, now: Date = Date()) throws -> URL? {
        let manager = FileManager.default
        let candidates = [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
        guard candidates.contains(where: { manager.fileExists(atPath: $0.path) }) else { return nil }
        let formatter = ISO8601DateFormatter()
        let safeDate = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let directory = url.deletingLastPathComponent()
            .appendingPathComponent("CorruptBackups", isDirectory: true)
            .appendingPathComponent("\(safeDate)-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var moved: [(source: URL, destination: URL)] = []
        do {
            for candidate in candidates where manager.fileExists(atPath: candidate.path) {
                let destination = directory.appendingPathComponent(candidate.lastPathComponent)
                try manager.moveItem(at: candidate, to: destination)
                moved.append((candidate, destination))
            }
        } catch {
            let originalError = error
            var rollbackMessages: [String] = []
            for item in moved.reversed() where manager.fileExists(atPath: item.destination.path) {
                do { try manager.moveItem(at: item.destination, to: item.source) }
                catch { rollbackMessages.append(error.localizedDescription) }
            }
            if !rollbackMessages.isEmpty {
                throw ProfileDatabaseError.recoveryRollback(
                    original: originalError.localizedDescription,
                    rollback: rollbackMessages.joined(separator: "; ")
                )
            }
            try? manager.removeItem(at: directory)
            throw originalError
        }
        return directory
    }

    public func save(_ profile: ConnectionProfile) throws {
        try save(
            profile,
            enforceProfileCount: true,
            enforceStorageLimit: true,
            enforceCredentialOwnership: true
        )
    }

    public func update(_ profile: ConnectionProfile) throws {
        guard try self.profile(id: profile.id) != nil else {
            throw ProfileDatabaseError.profileNotFound(profile.id)
        }
        try save(
            profile,
            enforceProfileCount: false,
            enforceStorageLimit: true,
            enforceCredentialOwnership: true
        )
    }

    public func saveAndReturnUnreferencedCredentialReferences(
        _ profile: ConnectionProfile,
        expectedToExist: Bool,
        expectedUpdatedAt: Date?,
        cleanupCandidates: Set<CredentialReference>
    ) throws -> Set<CredentialReference> {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let current = try self.profile(id: profile.id)
            let exists = current != nil
            if expectedToExist, !exists {
                throw ProfileDatabaseError.profileNotFound(profile.id)
            }
            if !expectedToExist, exists {
                throw ProfileDatabaseError.staleProfile(profile.id)
            }
            if let expectedUpdatedAt, current?.updatedAt != expectedUpdatedAt {
                throw ProfileDatabaseError.staleProfile(profile.id)
            }
            try save(
                profile,
                enforceProfileCount: !expectedToExist,
                enforceStorageLimit: true,
                enforceCredentialOwnership: true
            )
            let retained = try profiles().reduce(into: Set<CredentialReference>()) { result, profile in
                result.formUnion(profile.credentialReferences)
            }
            let unreferenced = cleanupCandidates.subtracting(retained)
            try execute("COMMIT;")
            return unreferenced
        } catch {
            let originalError = error
            do { try execute("ROLLBACK;") }
            catch {
                throw ProfileDatabaseError.rollback(
                    original: originalError.localizedDescription,
                    rollback: error.localizedDescription
                )
            }
            throw originalError
        }
    }

    private func save(
        _ profile: ConnectionProfile,
        enforceProfileCount: Bool,
        enforceStorageLimit: Bool,
        enforceCredentialOwnership: Bool
    ) throws {
        let profile = try profile.validated()
        if enforceProfileCount {
            guard try profileCount(excluding: profile.id) < Self.maximumProfileCount else {
                throw ProfileDatabaseError.tooManyProfiles(Self.maximumProfileCount)
            }
        }
        let data = try encoder.encode(profile)
        guard data.count <= Self.maximumProfilePayloadBytes else {
            throw ProfileDatabaseError.payloadTooLarge(Self.maximumProfilePayloadBytes)
        }
        if enforceStorageLimit {
            let existingBytes = try totalPayloadBytes(excluding: profile.id)
            guard existingBytes <= Self.maximumTotalProfilePayloadBytes - data.count else {
                throw ProfileDatabaseError.storageTooLarge(Self.maximumTotalProfilePayloadBytes)
            }
        }
        if enforceCredentialOwnership {
            var finalProfiles = try profiles().filter { $0.id != profile.id }
            finalProfiles.append(profile)
            try Self.validateCredentialOwnership(in: finalProfiles)
        }
        let sql = """
        INSERT INTO profiles(id, name, target_host, favorite, updated_at, payload)
        VALUES(?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          name=excluded.name, target_host=excluded.target_host, favorite=excluded.favorite,
          updated_at=excluded.updated_at, payload=excluded.payload;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(profile.id.uuidString, to: 1, in: statement)
        try bind(profile.name, to: 2, in: statement)
        try bind(profile.target.endpoint.host, to: 3, in: statement)
        guard sqlite3_bind_int(statement, 4, profile.isFavorite ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_double(statement, 5, profile.updatedAt.timeIntervalSince1970) == SQLITE_OK else {
            throw ProfileDatabaseError.execute(lastError)
        }
        let blobStatus = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(data.count), Self.transientDestructor)
        }
        guard blobStatus == SQLITE_OK else { throw ProfileDatabaseError.execute(lastError) }
        try stepDone(statement)
    }

    public func profile(id: UUID) throws -> ConnectionProfile? {
        let statement = try prepare("SELECT payload FROM profiles WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw ProfileDatabaseError.execute(lastError) }
        return try decodeProfile(statement, id: id)
    }

    public func profiles(search: String? = nil, favoritesOnly: Bool = false) throws -> [ConnectionProfile] {
        guard try totalPayloadBytes(excluding: nil) <= Self.maximumTotalProfilePayloadBytes else {
            throw ProfileDatabaseError.storageTooLarge(Self.maximumTotalProfilePayloadBytes)
        }
        var clauses: [String] = []
        if favoritesOnly { clauses.append("favorite = 1") }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let sql = "SELECT id, payload FROM profiles\(whereClause) ORDER BY favorite DESC, updated_at DESC, name COLLATE NOCASE LIMIT \(Self.maximumProfileCount + 1);"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let query = search.flatMap { $0.isEmpty ? nil : $0 }
        var result: [ConnectionProfile] = []
        var scannedCount = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ProfileDatabaseError.execute(lastError) }
            scannedCount += 1
            guard scannedCount <= Self.maximumProfileCount else {
                throw ProfileDatabaseError.tooManyProfiles(Self.maximumProfileCount)
            }
            guard let idText = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: idText)) else {
                throw ProfileDatabaseError.execute("Invalid profile identifier")
            }
            let profile = try decodeProfile(statement, id: id, payloadColumn: 1)
            if let query {
                if profile.matchesSearch(query) { result.append(profile) }
            } else {
                result.append(profile)
            }
        }
        return result
    }

    public func delete(id: UUID) throws {
        let statement = try prepare("DELETE FROM profiles WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    public func deleteAndReturnUnreferencedCredentialReferences(
        id: UUID
    ) throws -> Set<CredentialReference> {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let allProfiles = try profiles()
            guard let deleted = allProfiles.first(where: { $0.id == id }) else {
                try execute("COMMIT;")
                return []
            }
            let retainedReferences = allProfiles.lazy
                .filter { $0.id != id }
                .reduce(into: Set<CredentialReference>()) { result, profile in
                    result.formUnion(profile.credentialReferences)
                }
            try delete(id: id)
            try execute("COMMIT;")
            return deleted.credentialReferences.subtracting(retainedReferences)
        } catch {
            let originalError = error
            do { try execute("ROLLBACK;") }
            catch {
                throw ProfileDatabaseError.rollback(
                    original: originalError.localizedDescription,
                    rollback: error.localizedDescription
                )
            }
            throw originalError
        }
    }

    public func markConnected(id: UUID, at date: Date = Date()) throws {
        guard var current = try profile(id: id) else { return }
        current.lastConnectedAt = current.lastConnectedAt.map { max($0, date) } ?? date
        current.updatedAt = max(current.updatedAt, date)
        try save(
            current,
            enforceProfileCount: false,
            enforceStorageLimit: true,
            enforceCredentialOwnership: true
        )
    }

    public func exportProfiles() throws -> Data {
        guard try totalPayloadBytes(excluding: nil) <= Self.maximumArchiveBytes else {
            throw ProfileDatabaseError.archiveTooLarge(Self.maximumArchiveBytes)
        }
        let profiles = try profiles().map { profile -> ConnectionProfile in
            var sanitized = profile
            sanitized.redirection.drivePaths = []
            sanitized.redirection.sharedFolders = []
            return Self.removingCredentialReferences(from: sanitized)
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        defer { encoder.outputFormatting = [] }
        let data = try encoder.encode(ProfileArchive(profiles: profiles))
        guard data.count <= Self.maximumArchiveBytes else {
            throw ProfileDatabaseError.archiveTooLarge(Self.maximumArchiveBytes)
        }
        return data
    }

    public func importProfiles(from data: Data) throws -> Int {
        try importProfilesAndReturnUnreferencedCredentialReferences(from: data).importedCount
    }

    public func importProfilesAndReturnUnreferencedCredentialReferences(
        from data: Data
    ) throws -> ProfileImportResult {
        guard data.count <= Self.maximumArchiveBytes else {
            throw ProfileDatabaseError.archiveTooLarge(Self.maximumArchiveBytes)
        }
        let decoded: [ConnectionProfile]
        if let archive = try? decoder.decode(ProfileArchive.self, from: data) {
            guard (1...ProfileArchive.currentSchemaVersion).contains(archive.schemaVersion) else {
                throw ProfileDatabaseError.unsupportedSchema(archive.schemaVersion)
            }
            decoded = archive.profiles
        } else {
            decoded = try decoder.decode([ConnectionProfile].self, from: data)
        }
        let imported = try decoded.map {
            try Self.removingCredentialReferences(from: $0).validated()
        }
        guard imported.count <= Self.maximumProfileCount else {
            throw ProfileDatabaseError.tooManyProfiles(Self.maximumProfileCount)
        }
        let importedIDs = Set(imported.map(\.id))
        if importedIDs.count != imported.count {
            var seen = Set<UUID>()
            guard let duplicate = imported.first(where: {
                !seen.insert($0.id).inserted
            })?.id else {
                throw ProfileDatabaseError.execute(
                    "Could not identify a duplicate profile identifier."
                )
            }
            throw ProfileDatabaseError.duplicateProfileIdentifier(duplicate)
        }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let existingProfiles = try profiles()
            let existingCredentialReferences = existingProfiles.reduce(
                into: Set<CredentialReference>()
            ) { result, profile in
                result.formUnion(profile.credentialReferences)
            }
            var finalProfilesByID = Dictionary(
                uniqueKeysWithValues: existingProfiles.map { ($0.id, $0) }
            )
            for profile in imported { finalProfilesByID[profile.id] = profile }
            let finalProfiles = Array(finalProfilesByID.values)
            try Self.validateCredentialOwnership(in: finalProfiles)
            guard finalProfiles.count <= Self.maximumProfileCount else {
                throw ProfileDatabaseError.tooManyProfiles(Self.maximumProfileCount)
            }
            var payloadSizes = try storedProfilePayloadSizes()
            for profile in imported {
                let payload = try encoder.encode(profile)
                guard payload.count <= Self.maximumProfilePayloadBytes else {
                    throw ProfileDatabaseError.payloadTooLarge(Self.maximumProfilePayloadBytes)
                }
                payloadSizes[profile.id] = payload.count
            }
            var totalBytes = 0
            for size in payloadSizes.values {
                guard totalBytes <= Self.maximumTotalProfilePayloadBytes - size else {
                    throw ProfileDatabaseError.storageTooLarge(Self.maximumTotalProfilePayloadBytes)
                }
                totalBytes += size
            }
            for profile in imported {
                try save(
                    profile,
                    enforceProfileCount: false,
                    enforceStorageLimit: false,
                    enforceCredentialOwnership: false
                )
            }
            let retainedCredentialReferences = finalProfiles.reduce(
                into: Set<CredentialReference>()
            ) { result, profile in
                result.formUnion(profile.credentialReferences)
            }
            try execute("COMMIT;")
            return ProfileImportResult(
                importedCount: imported.count,
                unreferencedCredentialReferences: existingCredentialReferences
                    .subtracting(retainedCredentialReferences)
            )
        } catch {
            let originalError = error
            do { try execute("ROLLBACK;") }
            catch {
                throw ProfileDatabaseError.rollback(
                    original: originalError.localizedDescription,
                    rollback: error.localizedDescription
                )
            }
            throw originalError
        }
    }

    public func importProfiles(contentsOf url: URL) throws -> Int {
        try importProfilesAndReturnUnreferencedCredentialReferences(contentsOf: url)
            .importedCount
    }

    public func importProfilesAndReturnUnreferencedCredentialReferences(
        contentsOf url: URL
    ) throws -> ProfileImportResult {
        let data: Data
        do {
            data = try BoundedFileReader.read(from: url, maximumBytes: Self.maximumArchiveBytes)
        } catch is BoundedFileReadError {
            throw ProfileDatabaseError.archiveTooLarge(Self.maximumArchiveBytes)
        }
        return try importProfilesAndReturnUnreferencedCredentialReferences(from: data)
    }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func validateCredentialOwnership(
        in profiles: [ConnectionProfile]
    ) throws {
        var owners: [CredentialReference: UUID] = [:]
        for profile in profiles {
            for reference in profile.credentialReferences {
                if let owner = owners[reference], owner != profile.id {
                    throw ProfileDatabaseError.duplicateCredentialReference(reference)
                }
                owners[reference] = profile.id
            }
        }
    }

    private static func removingCredentialReferences(
        from profile: ConnectionProfile
    ) -> ConnectionProfile {
        var sanitized = profile
        sanitized.credentialReference = nil
        switch sanitized.route {
        case let .socks5(proxy):
            var proxy = proxy
            proxy.credentialReference = nil
            sanitized.route = .socks5(proxy)
        case let .httpConnect(proxy, tls):
            var proxy = proxy
            proxy.credentialReference = nil
            sanitized.route = .httpConnect(proxy: proxy, tls: tls)
        case let .rdGateway(gateway):
            var gateway = gateway
            gateway.credentialReference = nil
            sanitized.route = .rdGateway(gateway)
        case .direct:
            break
        }
        return sanitized
    }

    private static func migrate(_ db: OpaquePointer) throws {
        try execute(db, "PRAGMA journal_mode=WAL;")
        try execute(db, "PRAGMA foreign_keys=ON;")
        try execute(db, "PRAGMA busy_timeout=5000;")
        let version = Int(sqlite3_user_version(db))
        guard version >= 0 else {
            throw ProfileDatabaseError.execute("Could not read the database schema version.")
        }
        guard version <= currentSchemaVersion else { throw ProfileDatabaseError.unsupportedSchema(version) }
        if version < 1 {
            try execute(db, "BEGIN IMMEDIATE TRANSACTION;")
            do {
                try execute(db, """
                CREATE TABLE IF NOT EXISTS profiles(
                  id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, target_host TEXT NOT NULL,
                  favorite INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL, payload BLOB NOT NULL
                );
                """)
                try execute(db, "CREATE INDEX IF NOT EXISTS profiles_search ON profiles(name COLLATE NOCASE, target_host COLLATE NOCASE);")
                try execute(db, "PRAGMA user_version=1;")
                try execute(db, "COMMIT;")
            } catch {
                let originalError = error
                do { try execute(db, "ROLLBACK;") }
                catch {
                    throw ProfileDatabaseError.rollback(
                        original: originalError.localizedDescription,
                        rollback: error.localizedDescription
                    )
                }
                throw originalError
            }
        }
    }

    private static func sqlite3_user_version(_ db: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK, let statement else { return -1 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw ProfileDatabaseError.execute(message)
        }
    }

    private func execute(_ sql: String) throws { guard let db else { throw ProfileDatabaseError.open("closed") }; try Self.execute(db, sql) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw ProfileDatabaseError.open("closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProfileDatabaseError.prepare(lastError)
        }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor) == SQLITE_OK else {
            throw ProfileDatabaseError.execute(lastError)
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProfileDatabaseError.execute(lastError) }
    }

    private func profileCount(excluding id: UUID) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM profiles WHERE id <> ?;")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ProfileDatabaseError.execute(lastError)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func totalPayloadBytes(excluding id: UUID?) throws -> Int {
        let statement: OpaquePointer
        if let id {
            statement = try prepare("SELECT COALESCE(SUM(LENGTH(payload)), 0) FROM profiles WHERE id <> ?;")
            try bind(id.uuidString, to: 1, in: statement)
        } else {
            statement = try prepare("SELECT COALESCE(SUM(LENGTH(payload)), 0) FROM profiles;")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ProfileDatabaseError.execute(lastError)
        }
        let value = sqlite3_column_int64(statement, 0)
        guard value >= 0, UInt64(value) <= UInt64(Int.max) else {
            throw ProfileDatabaseError.storageTooLarge(Self.maximumTotalProfilePayloadBytes)
        }
        return Int(value)
    }

    private func storedProfilePayloadSizes() throws -> [UUID: Int] {
        let statement = try prepare("SELECT id, LENGTH(payload) FROM profiles LIMIT \(Self.maximumProfileCount + 1);")
        defer { sqlite3_finalize(statement) }
        var result: [UUID: Int] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: text)) else {
                throw ProfileDatabaseError.execute("Invalid profile identifier")
            }
            let size = sqlite3_column_int64(statement, 1)
            guard size >= 0, UInt64(size) <= UInt64(Self.maximumProfilePayloadBytes) else {
                throw ProfileDatabaseError.payloadTooLarge(Self.maximumProfilePayloadBytes)
            }
            result[id] = Int(size)
            guard result.count <= Self.maximumProfileCount else {
                throw ProfileDatabaseError.tooManyProfiles(Self.maximumProfileCount)
            }
        }
    }

    private func decodeProfile(_ statement: OpaquePointer, id: UUID, payloadColumn: Int32 = 0) throws -> ConnectionProfile {
        guard let bytes = sqlite3_column_blob(statement, payloadColumn) else {
            throw ProfileDatabaseError.decode(id, "Missing profile payload")
        }
        let count = Int(sqlite3_column_bytes(statement, payloadColumn))
        guard count >= 0, count <= Self.maximumProfilePayloadBytes else {
            throw ProfileDatabaseError.payloadTooLarge(Self.maximumProfilePayloadBytes)
        }
        do {
            let profile = try decoder.decode(ConnectionProfile.self, from: Data(bytes: bytes, count: count))
            guard profile.id == id else {
                throw ProfileDatabaseError.decode(id, "The payload identifier does not match its database row.")
            }
            return try profile.validated()
        }
        catch { throw ProfileDatabaseError.decode(id, error.localizedDescription) }
    }

    private var lastError: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed" }
}

private extension ConnectionProfile {
    func matchesSearch(_ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return name.range(of: query, options: options) != nil ||
            target.endpoint.host.range(of: query, options: options) != nil ||
            tags.contains { $0.range(of: query, options: options) != nil }
    }
}
