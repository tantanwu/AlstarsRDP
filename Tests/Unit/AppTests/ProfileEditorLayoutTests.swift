import AppKit
import Persistence
import RDPDomain
import XCTest
@testable import RemoteDesktop

final class ProfileEditorLayoutTests: XCTestCase {
    func testRouteTestButtonTitleChangesDoNotMoveNetworkContent() async {
        await MainActor.run {
            let profile = ConnectionProfile(
                name: "Test",
                target: TargetIdentity(endpoint: Endpoint(host: "rdp.example", port: 3389))
            )
            let controller = ProfileEditorWindowController(
                profile: profile,
                credentialStore: EmptyCredentialStore()
            )
            guard let window = controller.window,
                  let content = window.contentView,
                  let tabView = content.firstDescendant(ofType: NSTabView.self) else {
                XCTFail("The profile editor hierarchy was not created")
                return
            }

            tabView.selectTabViewItem(at: 2)
            content.layoutSubtreeIfNeeded()
            guard let networkView = tabView.tabViewItem(at: 2).view,
                  let button = networkView.descendants(ofType: NSButton.self).first(where: {
                      $0.action == NSSelectorFromString("testConnectionPath")
                  }),
                  let networkStack = button.superview as? NSStackView else {
                XCTFail("The Network tab controls were not created")
                return
            }

            let initialFrame = networkStack.frame
            for title in ["Cancel Test", "Test Connection", "Cancel Test", "Test Connection"] {
                button.title = title
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(button.frame.width, 120, accuracy: 0.5)
                XCTAssertEqual(networkStack.frame.origin.x, initialFrame.origin.x, accuracy: 0.5)
                XCTAssertEqual(networkStack.frame.origin.y, initialFrame.origin.y, accuracy: 0.5)
            }
        }
    }
}

private final class EmptyCredentialStore: CredentialStoring, @unchecked Sendable {
    func save(_ material: CredentialMaterial, reference: CredentialReference) throws {}
    func load(reference: CredentialReference) throws -> CredentialMaterial? { nil }
    func delete(reference: CredentialReference) throws {}
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        return subviews.lazy.compactMap { $0.firstDescendant(ofType: type) }.first
    }

    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        let direct = subviews.compactMap { $0 as? T }
        return direct + subviews.flatMap { $0.descendants(ofType: type) }
    }
}
