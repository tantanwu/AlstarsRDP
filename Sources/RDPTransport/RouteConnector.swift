import Diagnostics
import Foundation
import Network
import RDPDomain

public struct ConnectedRoute {
    public let connection: NWConnection
    public let targetIdentity: TargetIdentity
    public let prefetchedTargetData: Data
}

public final class RouteConnector: @unchecked Sendable {
    private let queue: DispatchQueue
    private let diagnostics: DiagnosticRecording?

    public init(queue: DispatchQueue = DispatchQueue(label: "com.example.RemoteDesktop.transport"), diagnostics: DiagnosticRecording? = nil) {
        self.queue = queue
        self.diagnostics = diagnostics
    }

    public func connect(
        target: TargetIdentity,
        route: RouteConfiguration,
        credential: ProxyCredential? = nil
    ) async throws -> ConnectedRoute {
        _ = try target.validated()
        _ = try route.validated()
        let routeName = Self.routeName(route)
        await diagnostics?.record(DiagnosticEvent(
            level: .info, category: .transport, code: "ROUTE_CONNECT_STARTED",
            message: "A connection route was started.",
            fields: ["route": .publicText(routeName), "targetHost": .privateText(target.endpoint.host)]
        ))
        do {
            let result: ConnectedRoute
            switch route {
            case .direct:
                let connection = try NWConnection.make(endpoint: target.endpoint)
                do { try await connection.waitUntilReady(on: queue) }
                catch { connection.cancel(); throw error }
                result = ConnectedRoute(connection: connection, targetIdentity: target, prefetchedTargetData: Data())
            case let .socks5(proxy):
                let connection = try NWConnection.make(endpoint: proxy.endpoint)
                do {
                    try await connection.waitUntilReady(on: queue)
                    try await negotiateSOCKS5(connection, target: target.endpoint, credential: credential)
                } catch {
                    connection.cancel()
                    throw error
                }
                result = ConnectedRoute(connection: connection, targetIdentity: target, prefetchedTargetData: Data())
            case let .httpConnect(proxy, tls):
                let connection = try NWConnection.make(
                    endpoint: proxy.endpoint,
                    tlsServerName: tls ? proxy.endpoint.host : nil
                )
                do {
                    try await connection.waitUntilReady(on: queue)
                    let prefetched = try await negotiateHTTPConnect(
                        connection, target: target.endpoint, credential: credential
                    )
                    result = ConnectedRoute(
                        connection: connection,
                        targetIdentity: target,
                        prefetchedTargetData: prefetched
                    )
                } catch {
                    connection.cancel()
                    throw error
                }
            case .rdGateway:
                throw SessionError(
                    category: .gateway,
                    code: "GATEWAY_NATIVE_ROUTE",
                    message: "RD Gateway is negotiated by the FreeRDP session core."
                )
            }
            await diagnostics?.record(DiagnosticEvent(
                level: .info, category: .transport, code: "ROUTE_CONNECT_SUCCEEDED",
                message: "The connection route is ready.",
                fields: ["route": .publicText(routeName), "targetHost": .privateText(target.endpoint.host)]
            ))
            return result
        } catch {
            await diagnostics?.record(DiagnosticEvent(
                level: .error, category: Self.diagnosticCategory(route), code: "ROUTE_CONNECT_FAILED",
                message: "A connection route failed.",
                fields: [
                    "route": .publicText(routeName),
                    "targetHost": .privateText(target.endpoint.host),
                    "errorDetail": .privateText(error.localizedDescription)
                ]
            ))
            throw error
        }
    }

    private static func routeName(_ route: RouteConfiguration) -> String {
        switch route {
        case .direct: return "direct"
        case .socks5: return "socks5"
        case let .httpConnect(_, tls): return tls ? "https-connect" : "http-connect"
        case .rdGateway: return "rd-gateway"
        }
    }

    private static func diagnosticCategory(_ route: RouteConfiguration) -> DiagnosticCategory {
        switch route {
        case .socks5, .httpConnect: return .proxy
        case .rdGateway: return .gateway
        case .direct: return .transport
        }
    }

    private func negotiateSOCKS5(
        _ connection: NWConnection,
        target: Endpoint,
        credential: ProxyCredential?
    ) async throws {
        try await connection.sendAll(SOCKS5Protocol.greeting(usesCredentials: credential != nil))
        let selection = try await connection.receiveExactly(2)
        let method = try SOCKS5Protocol.selectedAuthentication(from: selection, expectedCredentials: credential != nil)
        if method == 0x02 {
            guard let credential else { throw ProxyProtocolError.unsupportedAuthentication }
            try await connection.sendAll(try SOCKS5Protocol.usernamePasswordRequest(credential))
            try SOCKS5Protocol.validateAuthenticationResponse(try await connection.receiveExactly(2))
        }
        try await connection.sendAll(try SOCKS5Protocol.connectRequest(to: target))
        var response = try await connection.receiveExactly(5)
        let total = try SOCKS5Protocol.replyLength(from: response)
        if total > response.count { response.append(try await connection.receiveExactly(total - response.count)) }
    }

    private func negotiateHTTPConnect(
        _ connection: NWConnection,
        target: Endpoint,
        credential: ProxyCredential?
    ) async throws -> Data {
        try await connection.sendAll(try HTTPConnectProtocol.request(target: target, credential: credential))
        var response = Data()
        while true {
            guard let chunk = try await connection.receiveChunk(maximumLength: 4 * 1024) else {
                throw ProxyProtocolError.malformedResponse
            }
            response.append(chunk)
            if let parsed = try HTTPConnectProtocol.parseResponse(response) {
                return Data(response.dropFirst(parsed.headerLength))
            }
        }
    }
}
