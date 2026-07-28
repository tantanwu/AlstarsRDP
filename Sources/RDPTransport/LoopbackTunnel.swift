import Diagnostics
import Foundation
import Network
import RDPDomain

public struct LocalTunnelEndpoint: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var targetIdentity: TargetIdentity
}

typealias RouteConnectOperation = @Sendable (
    TargetIdentity,
    RouteConfiguration,
    ProxyCredential?
) async throws -> ConnectedRoute

public final class LoopbackTunnel: @unchecked Sendable {
    private let connectRoute: RouteConnectOperation
    private let queue = DispatchQueue(label: "com.example.RemoteDesktop.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTasks: [UUID: TunnelTaskHandle] = [:]
    private var preparedRoute: ConnectedRoute?
    private var generation: UInt64 = 0
    private var isRunning = false
    private var hasAcceptedConnection = false

    public init(routeConnector: RouteConnector) {
        connectRoute = { target, route, credential in
            try await routeConnector.connect(target: target, route: route, credential: credential)
        }
    }

    init(connectRoute: @escaping RouteConnectOperation) {
        self.connectRoute = connectRoute
    }

    deinit { stop() }

    public func start(
        target: TargetIdentity,
        route: RouteConfiguration,
        credential: ProxyCredential? = nil
    ) async throws -> LocalTunnelEndpoint {
        stop()
        _ = try target.validated()
        _ = try route.validated()
        let connectedRoute = try await connectRoute(target, route, credential)
        do {
            try Task.checkCancellation()
        } catch {
            connectedRoute.connection.cancel()
            throw error
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            connectedRoute.connection.cancel()
            throw error
        }
        let currentGeneration = prepare(
            listener: listener,
            connectedRoute: connectedRoute
        )

        listener.newConnectionHandler = { [weak self] downstream in
            self?.accept(downstream, generation: currentGeneration)
        }
        do {
            let port: UInt16 = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let gate = ListenerContinuationGate(continuation)
                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            guard self?.isActive(listener: listener, generation: currentGeneration) == true else {
                                gate.resume(throwing: CancellationError())
                                return
                            }
                            if let value = listener.port?.rawValue { gate.resume(returning: value) }
                            else { gate.resume(throwing: NetworkConnectionIOError.invalidPort) }
                        case let .failed(error): gate.resume(throwing: error)
                        case .cancelled: gate.resume(throwing: CancellationError())
                        default: break
                        }
                    }
                    listener.start(queue: queue)
                }
            }, onCancel: { [weak self] in
                self?.stop(generation: currentGeneration)
            })
            return LocalTunnelEndpoint(host: "127.0.0.1", port: port, targetIdentity: target)
        } catch {
            stop(generation: currentGeneration)
            throw error
        }
    }

    private func prepare(
        listener: NWListener,
        connectedRoute: ConnectedRoute
    ) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        self.preparedRoute = connectedRoute
        self.listener = listener
        connections[ObjectIdentifier(connectedRoute.connection)] = connectedRoute.connection
        isRunning = true
        hasAcceptedConnection = false
        return generation
    }

    public func stop() {
        stop(generation: nil)
    }

    private func stop(generation expectedGeneration: UInt64?) {
        lock.lock()
        if let expectedGeneration, expectedGeneration != generation {
            lock.unlock()
            return
        }
        generation &+= 1
        let active = Array(connections.values)
        connections.removeAll()
        let activeTasks = Array(connectionTasks.values)
        connectionTasks.removeAll()
        let currentListener = listener
        listener = nil
        preparedRoute = nil
        isRunning = false
        hasAcceptedConnection = false
        lock.unlock()
        activeTasks.forEach { $0.cancel() }
        active.forEach { $0.cancel() }
        currentListener?.cancel()
    }

    private func accept(_ downstream: NWConnection, generation: UInt64) {
        guard let configuration = claimConfiguration(for: generation) else {
            downstream.cancel()
            return
        }
        guard remember(downstream, generation: generation) else {
            configuration.listener.cancel()
            downstream.cancel()
            return
        }
        configuration.listener.cancel()
        let taskID = UUID()
        guard let taskHandle = reserveTask(id: taskID, generation: generation) else {
            downstream.cancel()
            return
        }
        let task = Task { [weak self] in
            guard let self else { downstream.cancel(); return }
            let upstream = configuration.connectedRoute.connection
            defer {
                downstream.cancel()
                upstream.cancel()
                self.forget(downstream)
                self.forget(upstream)
                self.forgetTask(taskID)
            }
            do {
                try await downstream.waitUntilReady(on: queue)
                if !configuration.connectedRoute.prefetchedTargetData.isEmpty {
                    try await downstream.sendAll(configuration.connectedRoute.prefetchedTargetData)
                }
                async let up: Void = relay(from: downstream, to: upstream)
                async let down: Void = relay(from: upstream, to: downstream)
                _ = try await (up, down)
            } catch { return }
        }
        taskHandle.install(task)
    }

    private func relay(from source: NWConnection, to destination: NWConnection) async throws {
        while let data = try await source.receiveChunk() {
            if data.isEmpty { continue }
            try await destination.sendAll(data)
        }
        destination.cancel()
    }

    private func claimConfiguration(
        for expectedGeneration: UInt64
    ) -> (connectedRoute: ConnectedRoute, listener: NWListener)? {
        lock.lock(); defer { lock.unlock() }
        guard expectedGeneration == generation,
              isRunning,
              !hasAcceptedConnection,
              let listener,
              let preparedRoute else { return nil }
        hasAcceptedConnection = true
        self.listener = nil
        self.preparedRoute = nil
        return (preparedRoute, listener)
    }

    private func remember(_ connection: NWConnection, generation expectedGeneration: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard expectedGeneration == generation, isRunning else { return false }
        connections[ObjectIdentifier(connection)] = connection
        return true
    }

    private func forget(_ connection: NWConnection) {
        lock.lock(); defer { lock.unlock() }
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func reserveTask(id: UUID, generation expectedGeneration: UInt64) -> TunnelTaskHandle? {
        lock.lock(); defer { lock.unlock() }
        guard expectedGeneration == generation, isRunning else { return nil }
        let handle = TunnelTaskHandle()
        connectionTasks[id] = handle
        return handle
    }

    private func forgetTask(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        connectionTasks.removeValue(forKey: id)
    }

    private func isActive(listener: NWListener, generation expectedGeneration: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return expectedGeneration == generation && isRunning && self.listener === listener
    }
}

private final class TunnelTaskHandle {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

private final class ListenerContinuationGate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
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
