import XCTest
@testable import Diagnostics

final class RedactorTests: XCTestCase {
    func testPrivateValuesAreRedactedByDefault() async throws {
        let timeline = DiagnosticTimeline()
        await timeline.record(DiagnosticEvent(
            level: .info, category: .transport, code: "CONNECTED", message: "Connected",
            fields: ["remoteHost": .privateText("private.example")]
        ))
        let export = try await timeline.export()
        let text = try XCTUnwrap(String(data: export, encoding: .utf8))
        XCTAssertFalse(text.contains("private.example"))
        XCTAssertTrue(text.contains("private:"))
    }

    func testForbiddenFieldNamesAreRejected() {
        XCTAssertFalse(Redactor.validateFieldNames(["proxyAuthorization": .publicText("x")]))
        XCTAssertTrue(Redactor.validateFieldNames(["statusCode": .number(200)]))
    }

    func testTimelineDoesNotRetainRejectedSensitiveField() async {
        let timeline = DiagnosticTimeline()
        await timeline.record(DiagnosticEvent(
            level: .debug, category: .proxy, code: "BAD_EVENT", message: "must be replaced",
            fields: ["proxyAuthorization": .publicText("Basic secret")]
        ))

        let events = await timeline.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].code, "DIAGNOSTIC_FIELDS_REJECTED")
        XCTAssertFalse(String(describing: events[0]).contains("Basic secret"))
    }

    func testPrivateErrorDetailsAreRedactedFromDefaultExport() async throws {
        let timeline = DiagnosticTimeline()
        await timeline.record(DiagnosticEvent(
            level: .error,
            category: .transport,
            code: "CONNECT_FAILED",
            message: "Connection preparation failed.",
            fields: ["errorDetail": .privateText("failed to connect to private.example:3389")]
        ))

        let data = try await timeline.export()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains("private.example"))
        XCTAssertTrue(text.contains("<private:"))
    }

    func testOversizedEventIsReplacedWithoutRetainingItsContent() async {
        let timeline = DiagnosticTimeline()
        let privateValue = String(repeating: "secret-host", count: 1_000)
        await timeline.record(DiagnosticEvent(
            level: .error,
            category: .transport,
            code: "OVERSIZED",
            message: "Connection failed.",
            fields: ["errorDetail": .privateText(privateValue)]
        ))

        let events = await timeline.snapshot()
        XCTAssertEqual(events.map(\.code), ["DIAGNOSTIC_EVENT_REJECTED"])
        XCTAssertFalse(String(describing: events).contains(privateValue))
    }

    func testInvalidNumbersAndExcessiveFieldCountsAreRejected() async {
        let timeline = DiagnosticTimeline()
        await timeline.record(DiagnosticEvent(
            level: .debug, category: .application, code: "NAN", message: "Invalid number",
            fields: ["value": .number(.nan)]
        ))
        let tooMany = Dictionary(uniqueKeysWithValues: (0...DiagnosticTimeline.maximumFieldCount).map {
            ("field\($0)", DiagnosticValue.boolean(true))
        })
        await timeline.record(DiagnosticEvent(
            level: .debug, category: .application, code: "FIELDS", message: "Too many fields",
            fields: tooMany
        ))

        let codes = await timeline.snapshot().map(\.code)
        XCTAssertEqual(codes, ["DIAGNOSTIC_EVENT_REJECTED", "DIAGNOSTIC_EVENT_REJECTED"])
    }

    func testExportLimitIsEnforcedAfterEncoding() async throws {
        let timeline = DiagnosticTimeline(maximumExportBytes: 1_024)
        for index in 0..<20 {
            await timeline.record(DiagnosticEvent(
                level: .info, category: .application, code: "EVENT_\(index)",
                message: String(repeating: "x", count: 100)
            ))
        }

        do {
            _ = try await timeline.export()
            XCTFail("Expected bounded export failure")
        } catch let error as DiagnosticTimelineError {
            XCTAssertEqual(error, .exportTooLarge(1_024))
        }
    }
}
