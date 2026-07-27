import Foundation
import Network
import RDPDomain

enum NetworkConnectionIOError: Error {
    case closed
    case invalidPort
}

extension NWConnection {
    static func make(endpoint: Endpoint, tlsServerName: String? = nil) throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw NetworkConnectionIOError.invalidPort }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        let parameters: NWParameters
        if let tlsServerName {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, tlsServerName)
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        return NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
    }

    func waitUntilReady(on queue: DispatchQueue) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ContinuationGate<Void>(continuation)
                stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.resume(returning: ())
                    case let .failed(error): gate.resume(throwing: error)
                    case .cancelled: gate.resume(throwing: CancellationError())
                    default: break
                    }
                }
                start(queue: queue)
            }
        }, onCancel: { cancel() })
    }

    func sendAll(_ data: Data) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: ()) }
                })
            }
        }, onCancel: { cancel() })
    }

    func receiveChunk(maximumLength: Int = 64 * 1024) async throws -> Data? {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(returning: nil) }
                    else { continuation.resume(returning: Data()) }
                }
            }
        }, onCancel: { cancel() })
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try await receiveChunk(maximumLength: count - result.count) else {
                throw NetworkConnectionIOError.closed
            }
            result.append(chunk)
        }
        return result
    }
}

private final class ContinuationGate<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(returning value: T) {
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
