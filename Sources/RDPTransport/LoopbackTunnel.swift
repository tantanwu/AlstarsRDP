import Diagnostics
import Foundation
import Network
import RDPDomain

public struct LocalTunnelEndpoint: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var targetIdentity: TargetIdentity
}

public final class LoopbackTunnel: @unchecked Sendable {
    private let routeConnector: RouteConnector
    private let queue = DispatchQueue(label: "com.example.RemoteDesktop.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionTasks: [UUID: TunnelTaskHandle] = [:]
    private var route: RouteConfiguration?
    private var target: TargetIdentity?
    private var credential: ProxyCredential?
    private var generation: UInt64 = 0
    private var isRunning = false
    private var hasAcceptedConnection = false

    public init(routeConnector: RouteConnector) { self.routeConnector = routeConnector }

    deinit { stop() }

    public func start(
        target: TargetIdentity,
        route: RouteConfiguration,
        credential: ProxyCredential? = nil
    ) async throws -> LocalTunnelEndpoint {
        stop()
        _ = try target.validated()
        _ = try route.validated()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let currentGeneration = prepare(
            listener: listener,
            target: target,
            route: route,
            credential: credential
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
        target: TargetIdentity,
        route: RouteConfiguration,
        credential: ProxyCredential?
    ) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        self.target = target
        self.route = route
        self.credential = credential
        self.listener = listener
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
        target = nil
        route = nil
        credential = nil
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
            var upstream: NWConnection?
            defer {
                downstream.cancel()
                upstream?.cancel()
                self.forget(downstream)
                if let upstream { self.forget(upstream) }
                self.forgetTask(taskID)
            }
            do {
                try await downstream.waitUntilReady(on: queue)
                let connected = try await routeConnector.connect(
                    target: configuration.target,
                    route: configuration.route,
                    credential: configuration.credential
                )
                upstream = connected.connection
                guard remember(connected.connection, generation: generation) else { return }
                if !connected.prefetchedTargetData.isEmpty {
                    try await downstream.sendAll(connected.prefetchedTargetData)
                }
                async let up: Void = relay(from: downstream, to: connected.connection)
                async let down: Void = relay(from: connected.connection, to: downstream)
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
    ) -> (target: TargetIdentity, route: RouteConfiguration, credential: ProxyCredential?, listener: NWListener)? {
        lock.lock(); defer { lock.unlock() }
        guard expectedGeneration == generation,
              isRunning,
              !hasAcceptedConnection,
              let listener,
              let target,
              let route else { return nil }
        hasAcceptedConnection = true
        self.listener = nil
        return (target, route, credential, listener)
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
