import Foundation
import XCTest
@testable import RDPTransport

final class RDPPathProbeTests: XCTestCase {
    func testConnectionRequestOffersTLSAndNLA() {
        XCTAssertEqual(RDPPathProbe.connectionRequest, Data([
            0x03, 0x00, 0x00, 0x13,
            0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00
        ]))
    }

    func testAcceptsX224ConnectionConfirm() throws {
        try RDPPathProbe.validateConnectionConfirm(Data([
            0x03, 0x00, 0x00, 0x13,
            0x0E, 0xD0, 0x00, 0x00, 0x12, 0x34, 0x00,
            0x02, 0x0F, 0x08, 0x00, 0x02, 0x00, 0x00, 0x00
        ]))
    }

    func testRejectsNonRDPAndTruncatedResponses() {
        XCTAssertThrowsError(try RDPPathProbe.validateConnectionConfirm(Data("HTTP/1.1 200 OK\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? RDPPathProbeError, .invalidResponse)
        }
        XCTAssertThrowsError(try RDPPathProbe.validateConnectionConfirm(Data([
            0x03, 0x00, 0x00, 0x13, 0x0E, 0xD0, 0x00
        ]))) {
            XCTAssertEqual($0 as? RDPPathProbeError, .invalidResponse)
        }
    }

    func testRejectsWrongX224PDUType() {
        var response = Data([
            0x03, 0x00, 0x00, 0x13,
            0x0E, 0xE0, 0x00, 0x00, 0x12, 0x34, 0x00,
            0x02, 0x0F, 0x08, 0x00, 0x02, 0x00, 0x00, 0x00
        ])
        response[5] = 0xE0
        XCTAssertThrowsError(try RDPPathProbe.validateConnectionConfirm(response)) {
            XCTAssertEqual($0 as? RDPPathProbeError, .invalidResponse)
        }
    }
}
