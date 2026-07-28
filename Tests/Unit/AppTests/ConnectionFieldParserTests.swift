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

    func testParsesCompleteDesktopSize() throws {
        let size = try ConnectionFieldParser.desktopSize(width: " 1920 ", height: "1080")
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }

    func testRejectsDesktopValuesThatWouldBeSilentlyReformattedOrTruncated() {
        for value in ["1,920", "1 920", "1920.0", "1920abc", "-1920", ""] {
            XCTAssertThrowsError(try ConnectionFieldParser.desktopSize(width: value, height: "1080"))
            XCTAssertThrowsError(try ConnectionFieldParser.desktopSize(width: "1920", height: value))
        }
    }

    func testRejectsDesktopSizeOutsideProtocolAndMemoryLimits() {
        for size in [
            ("319", "1080"),
            ("1920", "199"),
            ("16385", "1080"),
            ("1920", "16385"),
            ("16384", "4097")
        ] {
            XCTAssertThrowsError(try ConnectionFieldParser.desktopSize(width: size.0, height: size.1))
        }
    }
}
