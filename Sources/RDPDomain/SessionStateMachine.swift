import Foundation

public enum SessionPhase: String, Codable, Equatable, Sendable {
    case idle
    case resolving
    case connectingTransport
    case negotiatingProxyOrGateway
    case negotiatingTLS
    case authenticating
    case configuringChannels
    case connected
    case reconnecting
    case disconnecting
    case cancelling
    case closed
    case failed
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var phase: SessionPhase
    public var attempt: UInt8
    public var error: SessionError?
    public var changedAt: Date

    public init(
        phase: SessionPhase = .idle,
        attempt: UInt8 = 0,
        error: SessionError? = nil,
        changedAt: Date = Date()
    ) {
        self.phase = phase
        self.attempt = attempt
        self.error = error
        self.changedAt = changedAt
    }
}

public enum SessionEvent: Equatable, Sendable {
    case start
    case transportConnected(needsRouteNegotiation: Bool)
    case routeNegotiated
    case tlsNegotiated
    case authenticated
    case channelsConfigured
    case requestDisconnect
    case disconnected
    case retry(attempt: UInt8)
    case cancel
    case fail(SessionError)
}

public enum SessionStateTransitionError: Error, Equatable, LocalizedError, Sendable {
    case invalidTransition(from: SessionPhase, event: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidTransition(from, event):
            return "Cannot apply \(event) while the session is \(from.rawValue)."
        }
    }
}

public actor SessionStateMachine {
    private var current: SessionSnapshot

    public init(initial: SessionSnapshot = SessionSnapshot()) {
        current = initial
    }

    public func snapshot() -> SessionSnapshot { current }

    @discardableResult
    public func apply(_ event: SessionEvent, at date: Date = Date()) throws -> SessionSnapshot {
        let next: SessionSnapshot
        switch (current.phase, event) {
        case (.idle, .start):
            next = SessionSnapshot(phase: .resolving, changedAt: date)
        case (.resolving, .transportConnected(false)):
            next = SessionSnapshot(phase: .negotiatingTLS, changedAt: date)
        case (.resolving, .transportConnected(true)):
            next = SessionSnapshot(phase: .connectingTransport, changedAt: date)
        case (.connectingTransport, .routeNegotiated):
            next = SessionSnapshot(phase: .negotiatingProxyOrGateway, changedAt: date)
        case (.negotiatingProxyOrGateway, .tlsNegotiated), (.negotiatingTLS, .tlsNegotiated):
            next = SessionSnapshot(phase: .authenticating, changedAt: date)
        case (.authenticating, .authenticated):
            next = SessionSnapshot(phase: .configuringChannels, changedAt: date)
        case (.configuringChannels, .channelsConfigured):
            next = SessionSnapshot(phase: .connected, changedAt: date)
        case (.connected, .requestDisconnect), (.reconnecting, .requestDisconnect):
            next = SessionSnapshot(phase: .disconnecting, changedAt: date)
        case (.disconnecting, .disconnected), (.cancelling, .disconnected):
            next = SessionSnapshot(phase: .closed, changedAt: date)
        case (.connected, let .retry(attempt)):
            next = SessionSnapshot(phase: .reconnecting, attempt: attempt, changedAt: date)
        case (.reconnecting, .transportConnected(false)):
            next = SessionSnapshot(phase: .negotiatingTLS, attempt: current.attempt, changedAt: date)
        case (.reconnecting, .transportConnected(true)):
            next = SessionSnapshot(phase: .connectingTransport, attempt: current.attempt, changedAt: date)
        case (.resolving, .cancel), (.connectingTransport, .cancel),
             (.negotiatingProxyOrGateway, .cancel), (.negotiatingTLS, .cancel),
             (.authenticating, .cancel), (.configuringChannels, .cancel),
             (.reconnecting, .cancel):
            next = SessionSnapshot(phase: .cancelling, attempt: current.attempt, changedAt: date)
        case (.closed, .start), (.failed, .start):
            next = SessionSnapshot(phase: .resolving, changedAt: date)
        case (_, let .fail(error)) where current.phase != .closed:
            next = SessionSnapshot(phase: .failed, attempt: current.attempt, error: error, changedAt: date)
        default:
            throw SessionStateTransitionError.invalidTransition(
                from: current.phase,
                event: String(describing: event)
            )
        }
        current = next
        return next
    }
}

