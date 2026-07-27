import XCTest
@testable import RDPRenderer

final class FrameBufferValidationTests: XCTestCase {
    func testAcceptsCompleteBGRAFrame() {
        XCTAssertTrue(FrameBufferValidation.isValid(
            data: Data(repeating: 0, count: 16),
            width: 2,
            height: 2,
            stride: 8
        ))
    }

    func testRejectsShortOrOverflowingFrame() {
        XCTAssertFalse(FrameBufferValidation.isValid(
            data: Data(repeating: 0, count: 15),
            width: 2,
            height: 2,
            stride: 8
        ))
        XCTAssertFalse(FrameBufferValidation.isValid(
            data: Data(),
            width: Int.max,
            height: Int.max,
            stride: Int.max
        ))
    }
}
