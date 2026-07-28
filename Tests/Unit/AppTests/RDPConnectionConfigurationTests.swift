import RDPBridge
import RDPDomain
import XCTest
@testable import RemoteDesktop

final class RDPConnectionConfigurationTests: XCTestCase {
    func testTunnelUsesLoopbackForSocketAndOriginalTargetForServerIdentity() {
        let target = TargetIdentity(
            endpoint: Endpoint(host: "windows.example", port: 3389),
            certificateName: "rdp.example"
        )
        let configuration = RDPConnectionConfiguration()

        configuration.configureServerAddress(
            target: target,
            connectionEndpoint: Endpoint(host: "127.0.0.1", port: 49_152)
        )

        XCTAssertEqual(configuration.connectionHost, "127.0.0.1")
        XCTAssertEqual(configuration.connectionPort, 49_152)
        XCTAssertEqual(configuration.serverName, "windows.example")
        XCTAssertEqual(configuration.certificateName, "rdp.example")
    }

    func testConfigurationCopyPreservesServerIdentity() throws {
        let configuration = RDPConnectionConfiguration()
        configuration.connectionHost = "127.0.0.1"
        configuration.connectionPort = 49_152
        configuration.serverName = "windows.example"
        configuration.certificateName = "rdp.example"

        let copy = try XCTUnwrap(configuration.copy() as? RDPConnectionConfiguration)

        XCTAssertEqual(copy.connectionHost, configuration.connectionHost)
        XCTAssertEqual(copy.connectionPort, configuration.connectionPort)
        XCTAssertEqual(copy.serverName, configuration.serverName)
        XCTAssertEqual(copy.certificateName, configuration.certificateName)
    }
}
