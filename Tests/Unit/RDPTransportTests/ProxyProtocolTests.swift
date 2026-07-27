import XCTest
@testable import RDPTransport
import RDPDomain

final class ProxyProtocolTests: XCTestCase {
    func testSOCKS5DomainRequestPreservesRemoteDNSName() throws {
        let request = try SOCKS5Protocol.connectRequest(to: Endpoint(host: "internal.example", port: 3389))
        XCTAssertEqual(Array(request.prefix(5)), [0x05, 0x01, 0x00, 0x03, 16])
        XCTAssertTrue(String(data: request.dropFirst(5).dropLast(2), encoding: .utf8) == "internal.example")
        XCTAssertEqual(Array(request.suffix(2)), [0x0d, 0x3d])
    }

    func testSOCKS5EncodesIPLiteralAddressTypes() throws {
        let ipv4 = try SOCKS5Protocol.connectRequest(to: Endpoint(host: "127.0.0.1", port: 3389))
        let ipv6 = try SOCKS5Protocol.connectRequest(to: Endpoint(host: "2001:db8::10", port: 3389))

        XCTAssertEqual(Array(ipv4.prefix(8)), [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1])
        XCTAssertEqual(ipv4.count, 10)
        XCTAssertEqual(Array(ipv6.prefix(4)), [0x05, 0x01, 0x00, 0x04])
        XCTAssertEqual(ipv6.count, 22)
        XCTAssertEqual(Array(ipv6.suffix(2)), [0x0d, 0x3d])
    }

    func testSOCKS5RejectsUnadvertisedAuthentication() {
        XCTAssertThrowsError(
            try SOCKS5Protocol.selectedAuthentication(from: Data([0x05, 0x02]), expectedCredentials: false)
        )
    }

    func testSOCKS5UsernamePasswordRequestUsesUTF8ByteLengths() throws {
        let request = try SOCKS5Protocol.usernamePasswordRequest(
            ProxyCredential(username: "用户", password: "päss")
        )

        XCTAssertEqual(request[0], 0x01)
        XCTAssertEqual(Int(request[1]), Data("用户".utf8).count)
        let passwordLengthIndex = 2 + Data("用户".utf8).count
        XCTAssertEqual(Int(request[passwordLengthIndex]), Data("päss".utf8).count)
    }

    func testSOCKS5RejectsOversizedCredentialBeforeEncoding() {
        XCTAssertThrowsError(try SOCKS5Protocol.usernamePasswordRequest(
            ProxyCredential(username: String(repeating: "a", count: 256), password: "secret")
        )) {
            XCTAssertEqual($0 as? ProxyProtocolError, .invalidCredential)
        }
        XCTAssertThrowsError(try SOCKS5Protocol.usernamePasswordRequest(
            ProxyCredential(username: "alice", password: "")
        )) {
            XCTAssertEqual($0 as? ProxyProtocolError, .invalidCredential)
        }
    }

    func testSOCKS5ReplyLengthsAndRejection() throws {
        XCTAssertEqual(try SOCKS5Protocol.replyLength(from: Data([0x05, 0x00, 0x00, 0x01, 0x7f])), 10)
        XCTAssertEqual(try SOCKS5Protocol.replyLength(from: Data([0x05, 0x00, 0x00, 0x04, 0x00])), 22)
        XCTAssertEqual(try SOCKS5Protocol.replyLength(from: Data([0x05, 0x00, 0x00, 0x03, 0x0b])), 18)
        XCTAssertThrowsError(try SOCKS5Protocol.replyLength(from: Data([0x05, 0x05, 0x00, 0x01, 0x00]))) {
            XCTAssertEqual($0 as? ProxyProtocolError, .connectionRejected(code: 0x05))
        }
    }

    func testHTTPConnectRequestContainsBasicAuthorizationButNoNewlineInjection() throws {
        let request = try HTTPConnectProtocol.request(
            target: Endpoint(host: "rdp.example", port: 3389),
            credential: ProxyCredential(username: "alice", password: "secret")
        )
        let text = try XCTUnwrap(String(data: request, encoding: .utf8))
        XCTAssertTrue(text.contains("CONNECT rdp.example:3389 HTTP/1.1"))
        XCTAssertTrue(text.contains("Proxy-Authorization: Basic YWxpY2U6c2VjcmV0"))
        XCTAssertThrowsError(try HTTPConnectProtocol.request(
            target: Endpoint(host: "rdp.example", port: 3389),
            credential: ProxyCredential(username: "bad\r\nInjected", password: "x")
        ))
    }

    func testHTTPConnectParserHandlesPartialAndRejectsFailure() throws {
        XCTAssertNil(try HTTPConnectProtocol.parseResponse(Data("HTTP/1.1 200".utf8)))
        let success = try XCTUnwrap(HTTPConnectProtocol.parseResponse(Data(
            "HTTP/1.1 200 Connection established\r\nProxy-Agent: test\r\n\r\n".utf8
        )))
        XCTAssertEqual(success.statusCode, 200)
        XCTAssertThrowsError(try HTTPConnectProtocol.parseResponse(Data(
            "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8
        )))
    }

    func testHTTPConnectParserPreservesBytesAfterResponseHeader() throws {
        let targetBytes = Data([0x03, 0x00, 0x00, 0x13])
        var response = Data("HTTP/1.1 200 Connection established\r\nProxy-Agent: test\r\n\r\n".utf8)
        response.append(targetBytes)

        let parsed = try XCTUnwrap(HTTPConnectProtocol.parseResponse(response))

        XCTAssertEqual(Data(response.dropFirst(parsed.headerLength)), targetBytes)
    }

    func testHTTPConnectRejectsMalformedStatusAndHeaders() {
        XCTAssertThrowsError(try HTTPConnectProtocol.parseResponse(Data(
            "HTTP/2 200 OK\r\nProxy-Agent: test\r\n\r\n".utf8
        )))
        XCTAssertThrowsError(try HTTPConnectProtocol.parseResponse(Data(
            "HTTP/1.1 2000 OK\r\nProxy-Agent: test\r\n\r\n".utf8
        )))
        XCTAssertThrowsError(try HTTPConnectProtocol.parseResponse(Data(
            "HTTP/1.1 200 OK\r\nMissing-Colon\r\n\r\n".utf8
        )))
        XCTAssertThrowsError(try HTTPConnectProtocol.parseResponse(Data(
            "HTTP/1.1 200 OK\u{7f}\r\nProxy-Agent: test\r\n\r\n".utf8
        )))
        XCTAssertThrowsError(try HTTPConnectProtocol.parseResponse(Data(
            "HTTP/1.1 200 OK\r\nBad Header: test\r\n\r\n".utf8
        )))
    }

    func testHTTPHeaderLimit() {
        XCTAssertThrowsError(try HTTPConnectProtocol.parseResponse(Data(repeating: 65, count: 16 * 1024 + 1)))
    }

    func testHTTPConnectFormatsIPv6Authority() throws {
        let request = try HTTPConnectProtocol.request(
            target: Endpoint(host: "2001:db8::10", port: 3389),
            credential: nil
        )
        let text = try XCTUnwrap(String(data: request, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("CONNECT [2001:db8::10]:3389 HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: [2001:db8::10]:3389\r\n"))
    }

    func testHTTPConnectRejectsPasswordHeaderInjection() {
        XCTAssertThrowsError(try HTTPConnectProtocol.request(
            target: Endpoint(host: "rdp.example", port: 3389),
            credential: ProxyCredential(username: "alice", password: "secret\r\nInjected: true")
        ))
    }

    func testHTTPConnectRejectsInjectedUserAgentAndOversizedCredentials() {
        XCTAssertThrowsError(try HTTPConnectProtocol.request(
            target: Endpoint(host: "rdp.example", port: 3389),
            credential: nil,
            userAgent: "RemoteDesktop\r\nInjected: true"
        )) {
            XCTAssertEqual($0 as? ProxyProtocolError, .invalidHeaderValue)
        }
        XCTAssertThrowsError(try HTTPConnectProtocol.request(
            target: Endpoint(host: "rdp.example", port: 3389),
            credential: nil,
            userAgent: String(repeating: "a", count: HTTPConnectProtocol.maximumRequestBytes + 1)
        )) {
            XCTAssertEqual($0 as? ProxyProtocolError, .invalidHeaderValue)
        }
        XCTAssertThrowsError(try HTTPConnectProtocol.request(
            target: Endpoint(host: "rdp.example", port: 3389),
            credential: ProxyCredential(
                username: String(repeating: "a", count: HTTPConnectProtocol.maximumRequestBytes),
                password: "secret"
            )
        )) {
            XCTAssertEqual($0 as? ProxyProtocolError, .invalidCredential)
        }
        XCTAssertThrowsError(try HTTPConnectProtocol.request(
            target: Endpoint(host: "rdp.example", port: 3389),
            credential: ProxyCredential(username: "", password: "secret")
        )) {
            XCTAssertEqual($0 as? ProxyProtocolError, .invalidCredential)
        }
        XCTAssertThrowsError(try HTTPConnectProtocol.request(
            target: Endpoint(host: "rdp.example", port: 3389),
            credential: ProxyCredential(username: "alice", password: "")
        )) {
            XCTAssertEqual($0 as? ProxyProtocolError, .invalidCredential)
        }
    }
}
