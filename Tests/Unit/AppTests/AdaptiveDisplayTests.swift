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

    func testLegacyResizeFallbackWaitsForActivationAndRateLimitsReconnects() {
        XCTAssertEqual(
            AdaptiveResizeFallback.reconnectDelay(
                connectedAt: 100,
                lastReconnectAt: 0,
                now: 101
            ),
            1.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AdaptiveResizeFallback.reconnectDelay(
                connectedAt: 90,
                lastReconnectAt: 99,
                now: 100
            ),
            3,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AdaptiveResizeFallback.reconnectDelay(
                connectedAt: 90,
                lastReconnectAt: 0,
                now: 100
            ),
            0.75,
            accuracy: 0.001
        )
    }

    func testLegacyResizeFallbackRequiresKnownDifferentRemoteSize() throws {
        let target = try XCTUnwrap(AdaptiveDisplaySizing.metrics(
            canvasSizeInPoints: CGSize(width: 1_200, height: 800),
            backingScaleFactor: 1
        ))

        XCTAssertFalse(AdaptiveResizeFallback.requiresReconnect(
            target: target,
            remoteWidth: 0,
            remoteHeight: 0
        ))
        XCTAssertFalse(AdaptiveResizeFallback.requiresReconnect(
            target: target,
            remoteWidth: 1_200,
            remoteHeight: 800
        ))
        XCTAssertTrue(AdaptiveResizeFallback.requiresReconnect(
            target: target,
            remoteWidth: 1_180,
            remoteHeight: 712
        ))
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
            window.contentView?.layoutSubtreeIfNeeded()

            let buttons = window.contentView?.allDescendants(ofType: NSButton.self) ?? []
            let disconnect = buttons.first {
                $0.toolTip == NSLocalizedString("Disconnect", comment: "disconnect")
            }
            let fullScreen = buttons.first {
                $0.toolTip == NSLocalizedString("Toggle Full Screen", comment: "full screen")
            }
            XCTAssertNotNil(disconnect?.image)
            XCTAssertNotNil(fullScreen?.image)
            XCTAssertTrue(disconnect?.image?.isValid == true)
            XCTAssertTrue(fullScreen?.image?.isValid == true)
            XCTAssertGreaterThan(disconnect?.image?.size.width ?? 0, 0)
            XCTAssertGreaterThan(fullScreen?.image?.size.width ?? 0, 0)
            XCTAssertEqual(
                disconnect.map { $0.alignmentRect(forFrame: $0.frame).size },
                NSSize(width: 28, height: 28)
            )
            XCTAssertEqual(
                fullScreen.map { $0.alignmentRect(forFrame: $0.frame).size },
                NSSize(width: 28, height: 28)
            )

            controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
            window.contentView?.layoutSubtreeIfNeeded()
            let toolbarContainer = window.contentView?.allDescendants(ofType: SessionToolbarContainer.self).first
            XCTAssertEqual(toolbarContainer?.frame.height, 8)
            XCTAssertEqual(toolbarContainer?.frame.width, 72)

            toolbarContainer?.onHoverChanged?(true)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(toolbarContainer?.frame.height, 42)
            XCTAssertEqual(toolbarContainer?.frame.width, 388)

            let expectedTooltips = [
                NSLocalizedString("Disconnect", comment: "disconnect"),
                NSLocalizedString("Reconnect", comment: "reconnect"),
                NSLocalizedString("Toggle Full Screen", comment: "full screen"),
                NSLocalizedString("Send Control-Alt-Delete", comment: "cad")
            ]
            let toolbarButtons = buttons.filter { button in
                guard let tooltip = button.toolTip else { return false }
                return expectedTooltips.contains(tooltip)
            }
            XCTAssertEqual(toolbarButtons.count, expectedTooltips.count)
            guard let toolbarContainer else { return }
            for button in toolbarButtons {
                XCTAssertFalse(button.isHidden)
                let frame = button.convert(button.bounds, to: toolbarContainer)
                XCTAssertTrue(toolbarContainer.bounds.contains(frame), "\(button.toolTip ?? "button") was clipped")
            }

            let sizeLabel = window.contentView?.allDescendants(ofType: NSTextField.self).first {
                $0.toolTip == NSLocalizedString("Remote frame size", comment: "remote frame size")
            }
            sizeLabel?.stringValue = "7680x4320 > 8192x4608"
            sizeLabel?.isHidden = false
            window.contentView?.layoutSubtreeIfNeeded()
            let labelFrame = sizeLabel.map { $0.convert($0.bounds, to: toolbarContainer) } ?? .zero
            XCTAssertTrue(toolbarContainer.bounds.contains(labelFrame))
            for button in toolbarButtons {
                let frame = button.convert(button.bounds, to: toolbarContainer)
                XCTAssertFalse(frame.intersects(labelFrame), "\(button.toolTip ?? "button") overlapped the remote size")
            }
        }
    }
}

private extension NSView {
    func allDescendants<T: NSView>(ofType type: T.Type) -> [T] {
        let direct = subviews.compactMap { $0 as? T }
        return direct + subviews.flatMap { $0.allDescendants(ofType: type) }
    }
}

private final class AdaptiveDisplayEmptyCredentialStore: CredentialStoring, @unchecked Sendable {
    func save(_ material: CredentialMaterial, reference: CredentialReference) throws {}
    func load(reference: CredentialReference) throws -> CredentialMaterial? { nil }
    func delete(reference: CredentialReference) throws {}
}
