import Foundation
import RDPDomain

private let credentialTransactionGate = AsyncTransactionGate()

public struct CredentialWrite: Sendable {
    public var reference: CredentialReference
    public var material: CredentialMaterial

    public init(reference: CredentialReference, material: CredentialMaterial) {
        self.reference = reference
        self.material = material
    }
}

public enum ManagedProfileField: Hashable, Sendable {
    case reconnect
    case redirection
}

public enum ProfileSaveScope: Sendable {
    case fullProfile
    case credentialsOnly
}

public struct ProfileSaveRequest: Sendable {
    public var profile: ConnectionProfile
    public var credentialWrites: [CredentialWrite]
    public var obsoleteCredentialReferences: Set<CredentialReference>
    public var managedFieldChanges: Set<ManagedProfileField>
    public var scope: ProfileSaveScope
    public var baseProfile: ConnectionProfile?

    public init(
        profile: ConnectionProfile,
        credentialWrites: [CredentialWrite],
        obsoleteCredentialReferences: Set<CredentialReference>,
        managedFieldChanges: Set<ManagedProfileField> = [],
        scope: ProfileSaveScope = .fullProfile,
        baseProfile: ConnectionProfile? = nil
    ) {
        self.profile = profile
        self.credentialWrites = credentialWrites
        self.obsoleteCredentialReferences = obsoleteCredentialReferences
        self.managedFieldChanges = managedFieldChanges
        self.scope = scope
        self.baseProfile = baseProfile
    }
}

public struct CredentialCleanupFailure: Equatable, Sendable {
    public var reference: CredentialReference
    public var message: String

    public init(reference: CredentialReference, message: String) {
        self.reference = reference
        self.message = message
    }
}

public enum CredentialTransactionError: Error, LocalizedError, Equatable, Sendable {
    case duplicateWriteReference(CredentialReference)
    case writeNotReferencedByProfile(CredentialReference)
    case obsoleteReferenceStillUsed(CredentialReference)

    public var errorDescription: String? {
        switch self {
        case .duplicateWriteReference:
            return "A credential transaction contains duplicate writes for the same Keychain item."
        case .writeNotReferencedByProfile:
            return "A credential write is not referenced by the profile being saved."
        case .obsoleteReferenceStillUsed:
            return "A credential marked obsolete is still referenced by the profile being saved."
        }
    }
}

public struct CredentialRollbackError: Error, LocalizedError, Equatable, Sendable {
    public var persistenceMessage: String
    public var cleanupFailures: [CredentialCleanupFailure]

    public init(persistenceMessage: String, cleanupFailures: [CredentialCleanupFailure]) {
        self.persistenceMessage = persistenceMessage
        self.cleanupFailures = cleanupFailures
    }

    public var errorDescription: String? {
        "The profile was not saved and one or more Keychain changes could not be rolled back. Review Diagnostics."
    }
}

public enum CredentialTransaction {
    public static func commit(
        _ request: ProfileSaveRequest,
        credentialStore: CredentialStoring,
        persistProfile: () async throws -> Set<CredentialReference>
    ) async throws -> [CredentialCleanupFailure] {
        _ = try request.profile.validated()
        let retainedReferences = request.profile.credentialReferences
        var uniqueWrites = Set<CredentialReference>()
        for write in request.credentialWrites {
            guard uniqueWrites.insert(write.reference).inserted else {
                throw CredentialTransactionError.duplicateWriteReference(write.reference)
            }
            guard retainedReferences.contains(write.reference) else {
                throw CredentialTransactionError.writeNotReferencedByProfile(write.reference)
            }
        }
        if let retainedObsolete = request.obsoleteCredentialReferences
            .intersection(retainedReferences)
            .sorted(by: { $0.id.uuidString < $1.id.uuidString })
            .first {
            throw CredentialTransactionError.obsoleteReferenceStillUsed(retainedObsolete)
        }

        await credentialTransactionGate.acquire()
        defer { credentialTransactionGate.release() }
        try Task.checkCancellation()

        var writtenReferences: [CredentialReference] = []
        var previousMaterials: [CredentialReference: CredentialMaterial] = [:]
        do {
            for write in request.credentialWrites {
                if let previous = try credentialStore.load(reference: write.reference) {
                    previousMaterials[write.reference] = previous
                }
                try credentialStore.save(write.material, reference: write.reference)
                writtenReferences.append(write.reference)
            }
            let safeCleanupReferences = try await persistProfile()
            let approvedCleanupReferences = request.obsoleteCredentialReferences
                .intersection(safeCleanupReferences)
            return cleanup(
                approvedCleanupReferences,
                credentialStore: credentialStore
            )
        } catch {
            var rollbackFailures: [CredentialCleanupFailure] = []
            for reference in writtenReferences.reversed() {
                do {
                    if let previous = previousMaterials[reference] {
                        try credentialStore.save(previous, reference: reference)
                    } else {
                        try credentialStore.delete(reference: reference)
                    }
                }
                catch {
                    rollbackFailures.append(CredentialCleanupFailure(
                        reference: reference,
                        message: error.localizedDescription
                    ))
                }
            }
            if !rollbackFailures.isEmpty {
                throw CredentialRollbackError(
                    persistenceMessage: error.localizedDescription,
                    cleanupFailures: rollbackFailures
                )
            }
            throw error
        }

    }

    private static func cleanup(
        _ references: Set<CredentialReference>,
        credentialStore: CredentialStoring
    ) -> [CredentialCleanupFailure] {
        var cleanupFailures: [CredentialCleanupFailure] = []
        for reference in references.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            do { try credentialStore.delete(reference: reference) }
            catch {
                cleanupFailures.append(CredentialCleanupFailure(
                    reference: reference,
                    message: error.localizedDescription
                ))
            }
        }
        return cleanupFailures
    }
}

public enum ProfileDeletionTransaction {
    public static func commit(
        credentialStore: CredentialStoring,
        deleteProfile: () async throws -> Set<CredentialReference>
    ) async throws -> [CredentialCleanupFailure] {
        await credentialTransactionGate.acquire()
        defer { credentialTransactionGate.release() }
        try Task.checkCancellation()

        let referencesToDelete = try await deleteProfile()

        var cleanupFailures: [CredentialCleanupFailure] = []
        for reference in referencesToDelete.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            do { try credentialStore.delete(reference: reference) }
            catch {
                cleanupFailures.append(CredentialCleanupFailure(
                    reference: reference,
                    message: error.localizedDescription
                ))
            }
        }
        return cleanupFailures
    }
}

public enum CredentialCleanupTransaction {
    public static func commit<Result: Sendable>(
        credentialStore: CredentialStoring,
        mutation: () async throws -> (result: Result, referencesToDelete: Set<CredentialReference>)
    ) async throws -> (result: Result, cleanupFailures: [CredentialCleanupFailure]) {
        await credentialTransactionGate.acquire()
        defer { credentialTransactionGate.release() }
        try Task.checkCancellation()

        let mutationResult = try await mutation()
        var cleanupFailures: [CredentialCleanupFailure] = []
        for reference in mutationResult.referencesToDelete.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            do { try credentialStore.delete(reference: reference) }
            catch {
                cleanupFailures.append(CredentialCleanupFailure(
                    reference: reference,
                    message: error.localizedDescription
                ))
            }
        }
        return (mutationResult.result, cleanupFailures)
    }
}

private final class AsyncTransactionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isAcquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isAcquired {
                waiters.append(continuation)
                lock.unlock()
            } else {
                isAcquired = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            isAcquired = false
            lock.unlock()
            return
        }
        let continuation = waiters.removeFirst()
        lock.unlock()
        continuation.resume()
    }
}
