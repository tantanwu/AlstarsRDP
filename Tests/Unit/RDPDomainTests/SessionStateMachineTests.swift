import XCTest
@testable import RDPDomain

final class SessionStateMachineTests: XCTestCase {
    func testDirectConnectionHappyPath() async throws {
        let machine = SessionStateMachine()
        var snapshot = try await machine.apply(.start)
        XCTAssertEqual(snapshot.phase, .resolving)
        snapshot = try await machine.apply(.transportConnected(needsRouteNegotiation: false))
        XCTAssertEqual(snapshot.phase, .negotiatingTLS)
        snapshot = try await machine.apply(.tlsNegotiated)
        XCTAssertEqual(snapshot.phase, .authenticating)
        snapshot = try await machine.apply(.authenticated)
        XCTAssertEqual(snapshot.phase, .configuringChannels)
        snapshot = try await machine.apply(.channelsConfigured)
        XCTAssertEqual(snapshot.phase, .connected)
        snapshot = try await machine.apply(.requestDisconnect)
        XCTAssertEqual(snapshot.phase, .disconnecting)
        snapshot = try await machine.apply(.disconnected)
        XCTAssertEqual(snapshot.phase, .closed)
    }

    func testCancellationFromAuthenticationClosesCleanly() async throws {
        let machine = SessionStateMachine()
        _ = try await machine.apply(.start)
        _ = try await machine.apply(.transportConnected(needsRouteNegotiation: false))
        _ = try await machine.apply(.tlsNegotiated)
        var snapshot = try await machine.apply(.cancel)
        XCTAssertEqual(snapshot.phase, .cancelling)
        snapshot = try await machine.apply(.disconnected)
        XCTAssertEqual(snapshot.phase, .closed)
    }

    func testInvalidTransitionDoesNotMutateState() async throws {
        let machine = SessionStateMachine()
        do {
            _ = try await machine.apply(.authenticated)
            XCTFail("Expected invalid transition")
        } catch {
            let snapshot = await machine.snapshot()
            XCTAssertEqual(snapshot.phase, .idle)
        }
    }
}
