import Foundation
import Network
import RDPDomain
import XCTest
@testable import RDPTransport

final class LoopbackTunnelTests: XCTestCase {
    func testStartSurfacesRoutePreparationFailureBeforeOpeningLocalListener() async {
        let tunnel = LoopbackTunnel(connectRoute: { _, _, _ in
            throw ExpectedError.proxyUnavailable
        })
        let target = TargetIdentity(
            endpoint: Endpoint(host: "server.example", port: 3389)
        )
        let proxy = ProxyConfiguration(
            endpoint: Endpoint(host: "proxy.example", port: 1080)
        )

        do {
            _ = try await tunnel.start(target: target, route: .socks5(proxy))
            XCTFail("The tunnel returned a local endpoint before the proxy route was ready")
        } catch ExpectedError.proxyUnavailable {
            // Expected: the caller receives the proxy error directly.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRealSocketRelayIsBidirectionalAndListenerIsOneShot() async throws {
        let echoServer = try await EchoServer.start()
        defer { echoServer.stop() }
        let routeQueue = DispatchQueue(label: "LoopbackTunnelTests.upstream")
        let tunnel = LoopbackTunnel(connectRoute: { target, _, _ in
            let connection = try NWConnection.make(endpoint: echoServer.endpoint)
            try await connection.waitUntilReady(on: routeQueue)
            return ConnectedRoute(
                connection: connection,
                targetIdentity: target,
                prefetchedTargetData: Data("server-first".utf8)
            )
        })
        defer { tunnel.stop() }
        let target = TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389))
        let local = try await tunnel.start(target: target, route: .direct)
        let client = try NWConnection.make(endpoint: Endpoint(host: local.host, port: local.port))
        defer { client.cancel() }

        try await client.waitUntilReady(on: DispatchQueue(label: "LoopbackTunnelTests.client"))
        let serverFirst = try await client.receiveExactly(Data("server-first".utf8).count)
        XCTAssertEqual(serverFirst, Data("server-first".utf8))
        let payload = Data("rdp-through-loopback".utf8)
        try await client.sendAll(payload)
        let echoed = try await client.receiveExactly(payload.count)
        XCTAssertEqual(echoed, payload)

        let second = try NWConnection.make(endpoint: Endpoint(host: local.host, port: local.port))
        defer { second.cancel() }
        do {
            try await second.waitUntilReady(on: DispatchQueue(label: "LoopbackTunnelTests.second-client"))
            XCTFail("A one-shot tunnel accepted a second downstream connection")
        } catch {
            // Expected: the listener is cancelled only after the first socket is ready.
        }
    }

    func testStopCancelsAnActiveRelayAndTunnelCanBeStartedAgain() async throws {
        let echoServer = try await EchoServer.start()
        defer { echoServer.stop() }
        let routeQueue = DispatchQueue(label: "LoopbackTunnelTests.restart-upstream")
        let tunnel = LoopbackTunnel(connectRoute: { target, _, _ in
            let connection = try NWConnection.make(endpoint: echoServer.endpoint)
            try await connection.waitUntilReady(on: routeQueue)
            return ConnectedRoute(
                connection: connection,
                targetIdentity: target,
                prefetchedTargetData: Data()
            )
        })
        let target = TargetIdentity(endpoint: Endpoint(host: "server.example", port: 3389))

        let firstEndpoint = try await tunnel.start(target: target, route: .direct)
        let firstClient = try NWConnection.make(endpoint: Endpoint(host: firstEndpoint.host, port: firstEndpoint.port))
        try await firstClient.waitUntilReady(on: DispatchQueue(label: "LoopbackTunnelTests.first-client"))
        let firstPayload = Data("first".utf8)
        try await firstClient.sendAll(firstPayload)
        let firstEcho = try await firstClient.receiveExactly(firstPayload.count)
        XCTAssertEqual(firstEcho, firstPayload)
        tunnel.stop()
        firstClient.cancel()

        let secondEndpoint = try await tunnel.start(target: target, route: .direct)
        let secondClient = try NWConnection.make(endpoint: Endpoint(host: secondEndpoint.host, port: secondEndpoint.port))
        defer {
            secondClient.cancel()
            tunnel.stop()
        }
        try await secondClient.waitUntilReady(on: DispatchQueue(label: "LoopbackTunnelTests.restarted-client"))
        let secondPayload = Data("second".utf8)
        try await secondClient.sendAll(secondPayload)
        let secondEcho = try await secondClient.receiveExactly(secondPayload.count)
        XCTAssertEqual(secondEcho, secondPayload)
    }
}

private enum ExpectedError: Error {
    case proxyUnavailable
}

private final class EchoServer: @unchecked Sendable {
    private(set) var endpoint = Endpoint(host: "127.0.0.1", port: 1)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackTunnelTests.echo-server")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> EchoServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = EchoServer(listener: try NWListener(using: parameters, on: .any))
        let port = try await server.startAndWaitForPort()
        server.endpoint = Endpoint(host: "127.0.0.1", port: port)
        return server
    }

    private func startAndWaitForPort() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = PortContinuationGate(continuation)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if let port = listener?.port?.rawValue {
                        gate.resume(returning: port)
                    } else {
                        gate.resume(throwing: TestNetworkError.missingPort)
                    }
                case let .failed(error):
                    gate.resume(throwing: error)
                case .cancelled:
                    gate.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.echo(connection)
            case .failed, .cancelled:
                self.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { connection.cancel(); return }
                    if sendError == nil, !complete, error == nil {
                        self.echo(connection)
                    } else {
                        connection.cancel()
                        self.forget(connection)
                    }
                })
            } else if complete || error != nil {
                connection.cancel()
                self.forget(connection)
            } else {
                self.echo(connection)
            }
        }
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let active = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        active.forEach { $0.cancel() }
    }
}

private enum TestNetworkError: Error {
    case missingPort
}

private final class PortContinuationGate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: UInt16) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
