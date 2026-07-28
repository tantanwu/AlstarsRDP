import XCTest
@testable import RemoteDesktop

final class ConnectionFieldParserTests: XCTestCase {
    func testParsesCompletePortValue() throws {
        XCTAssertEqual(try ConnectionFieldParser.port("3389", field: "target"), 3389)
        XCTAssertEqual(try ConnectionFieldParser.port(" 1080 ", field: "proxy"), 1080)
    }

    func testRejectsValuesThatIntegerValueWouldSilentlyTruncate() {
        for value in ["3,389", "3 389", "3389abc", "3389.0"] {
            XCTAssertThrowsError(try ConnectionFieldParser.port(value, field: "target"))
        }
    }

    func testRejectsEmptyAndOutOfRangePorts() {
        for value in ["", "0", "65536", "-1"] {
            XCTAssertThrowsError(try ConnectionFieldParser.port(value, field: "target"))
        }
    }
}
