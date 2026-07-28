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
        configuration.desktopScaleFactor = 200
        configuration.deviceScaleFactor = 100

        let copy = try XCTUnwrap(configuration.copy() as? RDPConnectionConfiguration)

        XCTAssertEqual(copy.connectionHost, configuration.connectionHost)
        XCTAssertEqual(copy.connectionPort, configuration.connectionPort)
        XCTAssertEqual(copy.serverName, configuration.serverName)
        XCTAssertEqual(copy.certificateName, configuration.certificateName)
        XCTAssertEqual(copy.desktopScaleFactor, 200)
        XCTAssertEqual(copy.deviceScaleFactor, 100)
    }

    func testResizeRequestIsRejectedBeforeSessionConnects() {
        let configuration = RDPConnectionConfiguration()
        configuration.dynamicResolution = true
        let session = RDPSession(configuration: configuration)

        XCTAssertFalse(session.requestDesktopResize(
            width: 1_920,
            height: 1_080,
            desktopScaleFactor: 100,
            deviceScaleFactor: 100,
            physicalWidth: 508,
            physicalHeight: 286
        ))
    }
}
