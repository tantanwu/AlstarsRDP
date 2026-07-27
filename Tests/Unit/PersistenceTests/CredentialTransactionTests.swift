import XCTest
@testable import Persistence
import RDPDomain

final class CredentialTransactionTests: XCTestCase {
    func testCredentialMaterialRejectsNullAndOversizedValues() {
        XCTAssertThrowsError(try CredentialMaterial(
            username: "alice",
            password: ""
        ).validated())
        XCTAssertThrowsError(try CredentialMaterial(
            username: "alice",
            password: "bad\0password"
        ).validated())
        XCTAssertThrowsError(try CredentialMaterial(
            username: String(repeating: "a", count: CredentialMaterial.maximumUsernameBytes + 1),
            password: "secret"
        ).validated())
    }

    func testPersistenceFailureRemovesNewCredentialAndKeepsOldCredential() async throws {
        let store = MemoryCredentialStore()
        let oldReference = CredentialReference(kind: .target)
        let newReference = CredentialReference(kind: .target)
        let oldMaterial = CredentialMaterial(username: "old", password: "old-password")
        let newMaterial = CredentialMaterial(username: "new", password: "new-password")
        try store.save(oldMaterial, reference: oldReference)
        let request = makeRequest(
            reference: newReference,
            material: newMaterial,
            obsolete: [oldReference]
        )

        do {
            _ = try await CredentialTransaction.commit(request, credentialStore: store) {
                throw TestError.persistenceFailed
            }
            XCTFail("Expected persistence failure")
        } catch TestError.persistenceFailed {
            XCTAssertNil(try store.load(reference: newReference))
            XCTAssertEqual(try store.load(reference: oldReference), oldMaterial)
        }
    }

    func testSuccessfulPersistenceDeletesOldCredentialAfterCommit() async throws {
        let store = MemoryCredentialStore()
        let oldReference = CredentialReference(kind: .target)
        let newReference = CredentialReference(kind: .target)
        let oldMaterial = CredentialMaterial(username: "old", password: "old-password")
        let newMaterial = CredentialMaterial(username: "new", password: "new-password")
        try store.save(oldMaterial, reference: oldReference)
        let request = makeRequest(
            reference: newReference,
            material: newMaterial,
            obsolete: [oldReference]
        )

        let failures = try await CredentialTransaction.commit(request, credentialStore: store) {
            XCTAssertEqual(try store.load(reference: oldReference), oldMaterial)
            XCTAssertEqual(try store.load(reference: newReference), newMaterial)
            return [oldReference]
        }

        XCTAssertTrue(failures.isEmpty)
        XCTAssertNil(try store.load(reference: oldReference))
        XCTAssertEqual(try store.load(reference: newReference), newMaterial)
    }

    func testCleanupFailureDoesNotRollBackPersistedProfileOrNewCredential() async throws {
        let oldReference = CredentialReference(kind: .target)
        let newReference = CredentialReference(kind: .target)
        let store = MemoryCredentialStore(failingDeletes: [oldReference])
        let oldMaterial = CredentialMaterial(username: "old", password: "old-password")
        let newMaterial = CredentialMaterial(username: "new", password: "new-password")
        try store.save(oldMaterial, reference: oldReference)
        let request = makeRequest(
            reference: newReference,
            material: newMaterial,
            obsolete: [oldReference]
        )
        var didPersist = false

        let failures = try await CredentialTransaction.commit(request, credentialStore: store) {
            didPersist = true
            return [oldReference]
        }

        XCTAssertTrue(didPersist)
        XCTAssertEqual(failures.map(\.reference), [oldReference])
        XCTAssertEqual(try store.load(reference: newReference), newMaterial)
    }

    func testRollbackFailureIsReportedAndDoesNotHideOrphanedReference() async throws {
        let newReference = CredentialReference(kind: .target)
        let newMaterial = CredentialMaterial(username: "new", password: "new-password")
        let store = MemoryCredentialStore(failingDeletes: [newReference])
        let request = makeRequest(reference: newReference, material: newMaterial, obsolete: [])

        do {
            _ = try await CredentialTransaction.commit(request, credentialStore: store) {
                throw TestError.persistenceFailed
            }
            XCTFail("Expected rollback failure")
        } catch let error as CredentialRollbackError {
            XCTAssertEqual(error.cleanupFailures.map(\.reference), [newReference])
            XCTAssertEqual(try store.load(reference: newReference), newMaterial)
        }
    }

    func testPersistenceFailureRestoresCredentialThatWasOverwritten() async throws {
        let reference = CredentialReference(kind: .target)
        let oldMaterial = CredentialMaterial(username: "old", password: "old-password")
        let newMaterial = CredentialMaterial(username: "new", password: "new-password")
        let store = MemoryCredentialStore()
        try store.save(oldMaterial, reference: reference)
        let request = makeRequest(reference: reference, material: newMaterial, obsolete: [])

        do {
            _ = try await CredentialTransaction.commit(request, credentialStore: store) {
                throw TestError.persistenceFailed
            }
            XCTFail("Expected persistence failure")
        } catch TestError.persistenceFailed {
            XCTAssertEqual(try store.load(reference: reference), oldMaterial)
        }
    }

    func testConcurrentTransactionsCannotRollbackAnotherCommittedCredential() async throws {
        let reference = CredentialReference(kind: .target)
        let original = CredentialMaterial(username: "original", password: "original-password")
        let firstMaterial = CredentialMaterial(username: "first", password: "first-password")
        let secondMaterial = CredentialMaterial(username: "second", password: "second-password")
        let store = MemoryCredentialStore()
        let ordering = TransactionOrdering()
        try store.save(original, reference: reference)
        let firstRequest = makeRequest(reference: reference, material: firstMaterial, obsolete: [])
        let secondRequest = makeRequest(reference: reference, material: secondMaterial, obsolete: [])

        let first = Task {
            try await CredentialTransaction.commit(
                firstRequest,
                credentialStore: store
            ) {
                await ordering.firstDidEnterPersistence()
                await ordering.waitUntilFirstMayFinish()
                throw TestError.persistenceFailed
            }
        }
        while !(await ordering.hasFirstEnteredPersistence()) { await Task.yield() }

        let second = Task {
            try await CredentialTransaction.commit(
                secondRequest,
                credentialStore: store
            ) {
                await ordering.secondDidEnterPersistence()
                return Set<CredentialReference>()
            }
        }
        for _ in 0..<100 { await Task.yield() }
        let secondEnteredBeforeFirstFinished = await ordering.hasSecondEnteredPersistence()
        XCTAssertFalse(secondEnteredBeforeFirstFinished)
        XCTAssertEqual(try store.load(reference: reference), firstMaterial)

        await ordering.allowFirstToFinish()
        do {
            _ = try await first.value
            XCTFail("Expected the first transaction to fail")
        } catch TestError.persistenceFailed {}
        _ = try await second.value
        XCTAssertEqual(try store.load(reference: reference), secondMaterial)
    }

    func testRejectsDuplicateOrUnreferencedCredentialWritesBeforeMutation() async throws {
        let referenced = CredentialReference(kind: .target)
        let unrelated = CredentialReference(kind: .target)
        let material = CredentialMaterial(username: "alice", password: "secret")
        let store = MemoryCredentialStore()
        var duplicate = makeRequest(reference: referenced, material: material, obsolete: [])
        duplicate.credentialWrites.append(CredentialWrite(reference: referenced, material: material))

        do {
            _ = try await CredentialTransaction.commit(duplicate, credentialStore: store, persistProfile: { [] })
            XCTFail("Expected duplicate write rejection")
        } catch let error as CredentialTransactionError {
            XCTAssertEqual(error, .duplicateWriteReference(referenced))
        }

        var unreferenced = makeRequest(reference: referenced, material: material, obsolete: [])
        unreferenced.credentialWrites = [CredentialWrite(reference: unrelated, material: material)]
        do {
            _ = try await CredentialTransaction.commit(unreferenced, credentialStore: store, persistProfile: { [] })
            XCTFail("Expected unreferenced write rejection")
        } catch let error as CredentialTransactionError {
            XCTAssertEqual(error, .writeNotReferencedByProfile(unrelated))
        }
        XCTAssertNil(try store.load(reference: referenced))
        XCTAssertNil(try store.load(reference: unrelated))
    }

    func testRejectsDeletingCredentialStillReferencedBySavedProfile() async throws {
        let reference = CredentialReference(kind: .target)
        let material = CredentialMaterial(username: "alice", password: "secret")
        let request = makeRequest(reference: reference, material: material, obsolete: [reference])
        let store = MemoryCredentialStore()

        do {
            _ = try await CredentialTransaction.commit(request, credentialStore: store, persistProfile: { [] })
            XCTFail("Expected retained obsolete reference rejection")
        } catch let error as CredentialTransactionError {
            XCTAssertEqual(error, .obsoleteReferenceStillUsed(reference))
        }
        XCTAssertNil(try store.load(reference: reference))
    }

    func testProfileDeletionFailureKeepsCredentials() async throws {
        let reference = CredentialReference(kind: .target)
        let material = CredentialMaterial(username: "alice", password: "secret")
        let store = MemoryCredentialStore()
        try store.save(material, reference: reference)
        do {
            _ = try await ProfileDeletionTransaction.commit(credentialStore: store) {
                throw TestError.persistenceFailed
            }
            XCTFail("Expected persistence failure")
        } catch TestError.persistenceFailed {
            XCTAssertEqual(try store.load(reference: reference), material)
        }
    }

    func testSuccessfulProfileDeletionRemovesCredentials() async throws {
        let reference = CredentialReference(kind: .target)
        let store = MemoryCredentialStore()
        try store.save(CredentialMaterial(username: "alice", password: "secret"), reference: reference)

        let failures = try await ProfileDeletionTransaction.commit(
            credentialStore: store,
            deleteProfile: { [reference] }
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertNil(try store.load(reference: reference))
    }

    func testProfileDeletionReportsCredentialCleanupFailure() async throws {
        let reference = CredentialReference(kind: .target)
        let store = MemoryCredentialStore(failingDeletes: [reference])
        try store.save(CredentialMaterial(username: "alice", password: "secret"), reference: reference)
        var didDeleteProfile = false

        let failures = try await ProfileDeletionTransaction.commit(
            credentialStore: store
        ) {
            didDeleteProfile = true
            return [reference]
        }

        XCTAssertTrue(didDeleteProfile)
        XCTAssertEqual(failures.map(\.reference), [reference])
    }

    func testCredentialCleanupTransactionDeletesOnlyMutationApprovedReferences() async throws {
        let removedReference = CredentialReference(kind: .target)
        let retainedReference = CredentialReference(kind: .proxy)
        let store = MemoryCredentialStore()
        let material = CredentialMaterial(username: "alice", password: "secret")
        try store.save(material, reference: removedReference)
        try store.save(material, reference: retainedReference)

        let result = try await CredentialCleanupTransaction.commit(credentialStore: store) {
            (result: 1, referencesToDelete: Set([removedReference]))
        }

        XCTAssertEqual(result.result, 1)
        XCTAssertTrue(result.cleanupFailures.isEmpty)
        XCTAssertNil(try store.load(reference: removedReference))
        XCTAssertEqual(try store.load(reference: retainedReference), material)
    }

    private func makeRequest(
        reference: CredentialReference,
        material: CredentialMaterial,
        obsolete: Set<CredentialReference>
    ) -> ProfileSaveRequest {
        ProfileSaveRequest(
            profile: ConnectionProfile(
                name: "Test",
                target: TargetIdentity(endpoint: Endpoint(host: "test.example", port: 3389)),
                credentialReference: reference
            ),
            credentialWrites: [CredentialWrite(reference: reference, material: material)],
            obsoleteCredentialReferences: obsolete
        )
    }

    private func makeProfile(reference: CredentialReference) -> ConnectionProfile {
        ConnectionProfile(
            name: "Test",
            target: TargetIdentity(endpoint: Endpoint(host: "test.example", port: 3389)),
            credentialReference: reference
        )
    }
}

private enum TestError: Error {
    case persistenceFailed
    case deleteFailed
}

private actor TransactionOrdering {
    private var firstEnteredPersistence = false
    private var secondEnteredPersistence = false
    private var firstMayFinish = false
    private var firstWaiters: [CheckedContinuation<Void, Never>] = []

    func firstDidEnterPersistence() { firstEnteredPersistence = true }
    func secondDidEnterPersistence() { secondEnteredPersistence = true }
    func hasFirstEnteredPersistence() -> Bool { firstEnteredPersistence }
    func hasSecondEnteredPersistence() -> Bool { secondEnteredPersistence }

    func waitUntilFirstMayFinish() async {
        if firstMayFinish { return }
        await withCheckedContinuation { continuation in
            firstWaiters.append(continuation)
        }
    }

    func allowFirstToFinish() {
        firstMayFinish = true
        let waiters = firstWaiters
        firstWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class MemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialReference: CredentialMaterial] = [:]
    private let failingDeletes: Set<CredentialReference>

    init(failingDeletes: Set<CredentialReference> = []) {
        self.failingDeletes = failingDeletes
    }

    func save(_ material: CredentialMaterial, reference: CredentialReference) throws {
        lock.lock(); defer { lock.unlock() }
        values[reference] = material
    }

    func load(reference: CredentialReference) throws -> CredentialMaterial? {
        lock.lock(); defer { lock.unlock() }
        return values[reference]
    }

    func delete(reference: CredentialReference) throws {
        lock.lock(); defer { lock.unlock() }
        if failingDeletes.contains(reference) { throw TestError.deleteFailed }
        values.removeValue(forKey: reference)
    }
}
