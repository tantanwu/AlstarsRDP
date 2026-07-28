import AppKit
import XCTest
@testable import RemoteDesktop

final class ApplicationLifecycleTests: XCTestCase {
    func testApplicationInstallsDelegateAndShowsMainWindow() async {
        await MainActor.run {
            XCTAssertTrue(NSApp.delegate is AppDelegate)

            let mainWindows = NSApp.windows.filter {
                $0.windowController is ConnectionLibraryWindowController
            }
            XCTAssertEqual(mainWindows.count, 1)
            guard let mainWindow = mainWindows.first else {
                XCTFail("The connection library window was not created")
                return
            }
            XCTAssertTrue(mainWindow.isVisible)

            let fullScreenItem = NSApp.windowsMenu?.items.first {
                $0.action == #selector(NSWindow.toggleFullScreen(_:))
            }
            XCTAssertEqual(fullScreenItem?.keyEquivalent, "f")
            XCTAssertEqual(fullScreenItem?.keyEquivalentModifierMask, [.control, .command])
        }
    }
}
