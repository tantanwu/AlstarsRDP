import AppKit
import Diagnostics
import Persistence
import RDPDomain
import XCTest
@testable import RemoteDesktop

final class AdaptiveDisplayTests: XCTestCase {
    func testUsesCanvasBackingPixelsAndRetinaScale() throws {
        let metrics = try XCTUnwrap(AdaptiveDisplaySizing.metrics(
            canvasSizeInPoints: CGSize(width: 1_000, height: 600),
            backingScaleFactor: 2
        ))

        XCTAssertEqual(metrics.width, 2_000)
        XCTAssertEqual(metrics.height, 1_200)
        XCTAssertEqual(metrics.desktopScaleFactor, 200)
        XCTAssertEqual(metrics.deviceScaleFactor, 100)
        XCTAssertEqual(metrics.physicalWidth, 265)
        XCTAssertEqual(metrics.physicalHeight, 159)
    }

    func testRoundsWidthToEvenAndConstrainsProtocolDimensions() throws {
        let ordinary = try XCTUnwrap(AdaptiveDisplaySizing.metrics(
            canvasSizeInPoints: CGSize(width: 1_001, height: 701),
            backingScaleFactor: 1
        ))
        XCTAssertEqual(ordinary.width, 1_000)
        XCTAssertEqual(ordinary.height, 701)

        let oversized = try XCTUnwrap(AdaptiveDisplaySizing.metrics(
            canvasSizeInPoints: CGSize(width: 20_000, height: 10_000),
            backingScaleFactor: 1
        ))
        XCTAssertEqual(oversized.width, 8_192)
        XCTAssertEqual(oversized.height, 4_096)
        XCTAssertLessThanOrEqual(
            UInt64(oversized.width) * UInt64(oversized.height),
            DisplayConfiguration.maximumPixelCount
        )
    }

    func testRejectsInvalidCanvasGeometry() {
        XCTAssertNil(AdaptiveDisplaySizing.metrics(
            canvasSizeInPoints: .zero,
            backingScaleFactor: 1
        ))
        XCTAssertNil(AdaptiveDisplaySizing.metrics(
            canvasSizeInPoints: CGSize(width: 1_000, height: 600),
            backingScaleFactor: 0
        ))
    }

    func testCommonResolutionLookup() {
        XCTAssertEqual(DisplayResolutionPreset.index(width: 1_920, height: 1_080), 3)
        XCTAssertNil(DisplayResolutionPreset.index(width: 1_366, height: 768))
    }

    func testSessionWindowUsesNativeFullScreenBehavior() async {
        await MainActor.run {
            let profile = ConnectionProfile(
                name: "Full Screen",
                target: TargetIdentity(endpoint: Endpoint(host: "rdp.example", port: 3389))
            )
            let controller = SessionWindowController(
                sessionID: UUID(),
                profile: profile,
                credentialStore: AdaptiveDisplayEmptyCredentialStore(),
                diagnostics: DiagnosticTimeline(),
                automaticReconnectEnabled: false,
                onProfileUpdate: { _ in },
                onClose: { _ in }
            )

            guard let window = controller.window else {
                XCTFail("The session window was not created")
                return
            }
            XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
            XCTAssertFalse(window.styleMask.contains(.fullScreen))
            XCTAssertTrue(window.styleMask.contains(.resizable))
        }
    }
}

private final class AdaptiveDisplayEmptyCredentialStore: CredentialStoring, @unchecked Sendable {
    func save(_ material: CredentialMaterial, reference: CredentialReference) throws {}
    func load(reference: CredentialReference) throws -> CredentialMaterial? { nil }
    func delete(reference: CredentialReference) throws {}
}
