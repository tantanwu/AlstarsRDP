import AppKit
import Diagnostics
import Persistence

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var libraryWindowController: ConnectionLibraryWindowController?
    private var pendingOpenFiles: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        do {
            let database = try openDatabase()
            let credentials = KeychainCredentialStore()
            let diagnostics = DiagnosticTimeline()
            let settings = ApplicationSettingsStore(policy: EnterprisePolicy.loadManaged())
            let controller = ConnectionLibraryWindowController(
                database: database, credentialStore: credentials, diagnostics: diagnostics, settings: settings
            )
            controller.onEditorClosed = { [weak self] in self?.openPendingFiles() }
            libraryWindowController = controller
            buildMainMenu(settingsTarget: controller)
            controller.showWindow(nil)
            openPendingFiles()
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = NSLocalizedString("Unable to start RemoteDesktop", comment: "startup failure")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        pendingOpenFiles.append(contentsOf: filenames)
        openPendingFiles()
        sender.reply(toOpenOrPrint: .success)
    }

    private func openPendingFiles() {
        guard let controller = libraryWindowController,
              controller.canPresentConnectionEditor,
              let first = pendingOpenFiles.first else { return }
        pendingOpenFiles.removeFirst()
        do {
            try controller.importRDPFile(at: URL(fileURLWithPath: first))
        } catch {
            let alert = NSAlert(error: error)
            if let window = controller.window {
                alert.beginSheetModal(for: window) { [weak self] _ in self?.openPendingFiles() }
            } else {
                alert.runModal()
                openPendingFiles()
            }
        }
    }

    private func openDatabase() throws -> ProfileDatabase {
        let url = try ProfileDatabase.defaultURL()
        do { return try ProfileDatabase(url: url) }
        catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = NSLocalizedString("The connection database cannot be opened", comment: "database damaged")
            alert.informativeText = NSLocalizedString("RemoteDesktop can move the existing database into a recovery folder and create a new empty database. Stored Keychain credentials are not deleted.", comment: "database recovery detail") + "\n\n" + error.localizedDescription
            alert.addButton(withTitle: NSLocalizedString("Back Up and Reset", comment: "reset database"))
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: "quit"))
            guard alert.runModal() == .alertFirstButtonReturn else { throw error }
            _ = try ProfileDatabase.quarantineStore(at: url)
            return try ProfileDatabase(url: url)
        }
    }

    private func buildMainMenu(settingsTarget: ConnectionLibraryWindowController) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: NSLocalizedString("About RemoteDesktop", comment: "about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = NSMenuItem(title: NSLocalizedString("Settings…", comment: "settings menu"), action: #selector(ConnectionLibraryWindowController.showSettings), keyEquivalent: ",")
        settings.target = settingsTarget
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Hide RemoteDesktop", comment: "hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: NSLocalizedString("Hide Others", comment: "hide others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: NSLocalizedString("Show All", comment: "show all"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Quit RemoteDesktop", comment: "quit app"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: NSLocalizedString("Window", comment: "window menu"))
        windowMenu.addItem(withTitle: NSLocalizedString("Minimize", comment: "minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: NSLocalizedString("Zoom", comment: "zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: NSLocalizedString("Bring All to Front", comment: "bring front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }
}
