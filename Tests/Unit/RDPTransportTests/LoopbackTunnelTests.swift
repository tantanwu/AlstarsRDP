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
}

private enum ExpectedError: Error {
    case proxyUnavailable
}
