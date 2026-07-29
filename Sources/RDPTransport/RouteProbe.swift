import Diagnostics
import Foundation
import Network
import RDPDomain

public enum RouteProbeStage: String, Codable, Sendable {
    case targetTCP
    case socks5Tunnel
    case httpConnectTunnel
    case httpsConnectTunnel
    case rdGatewayTLS
}

public struct RouteProbeReport: Codable, Equatable, Sendable {
    public var stage: RouteProbeStage
    public var durationMilliseconds: Int
    public var targetIdentity: TargetIdentity
    public var certificateName: String

    public init(stage: RouteProbeStage, durationMilliseconds: Int, targetIdentity: TargetIdentity, certificateName: String) {
        self.stage = stage
        self.durationMilliseconds = durationMilliseconds
        self.targetIdentity = targetIdentity
        self.certificateName = certificateName
    }
}

public struct RouteProbeError: Error, LocalizedError, Sendable {
    public var stage: RouteProbeStage
    public var underlyingDescription: String

    public var errorDescription: String? {
        String(
            format: NSLocalizedString(
                "The connection path failed during %@: %@",
                comment: "route probe failure"
            ),
            stage.rawValue,
            underlyingDescription
        )
    }
}

public final class RouteProbe: @unchecked Sendable {
    private let connector: RouteConnector
    private let queue = DispatchQueue(label: "com.example.RemoteDesktop.route-probe")

    public init(diagnostics: DiagnosticRecording? = nil) {
        connector = RouteConnector(diagnostics: diagnostics)
    }

    public func test(
        target: TargetIdentity,
        route: RouteConfiguration,
        credential: ProxyCredential? = nil
    ) async throws -> RouteProbeReport {
        let stage = Self.stage(for: route)
        return try await withThrowingTaskGroup(of: RouteProbeReport.self) { group in
            group.addTask { [self] in
                try await performTest(target: target, route: route, credential: credential, stage: stage)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw RouteProbeError(stage: stage, underlyingDescription: "Timed out after 15 seconds.")
            }
            defer { group.cancelAll() }
            guard let report = try await group.next() else { throw CancellationError() }
            return report
        }
    }

    private func performTest(
        target: TargetIdentity,
        route: RouteConfiguration,
        credential: ProxyCredential?,
        stage: RouteProbeStage
    ) async throws -> RouteProbeReport {
        let started = Date()
        do {
            _ = try target.validated()
            _ = try route.validated()
            let certificateName: String
            switch route {
            case let .rdGateway(gateway):
                let connection = try NWConnection.make(endpoint: gateway.endpoint, tlsServerName: gateway.endpoint.host)
                defer { connection.cancel() }
                try await connection.waitUntilReady(on: queue)
                certificateName = gateway.endpoint.host
            default:
                let connected = try await connector.connect(target: target, route: route, credential: credential)
                defer { connected.connection.cancel() }
                try await RDPPathProbe.verify(
                    connection: connected.connection,
                    prefetchedData: connected.prefetchedTargetData
                )
                certificateName = target.certificateName
            }
            return RouteProbeReport(
                stage: stage,
                durationMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1_000)),
                targetIdentity: target,
                certificateName: certificateName
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RouteProbeError(stage: stage, underlyingDescription: error.localizedDescription)
        }
    }

    private static func stage(for route: RouteConfiguration) -> RouteProbeStage {
        switch route {
        case .direct: return .targetTCP
        case .socks5: return .socks5Tunnel
        case let .httpConnect(_, tls): return tls ? .httpsConnectTunnel : .httpConnectTunnel
        case .rdGateway: return .rdGatewayTLS
        }
    }
}
