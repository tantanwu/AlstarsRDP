import AppKit
import Diagnostics
import Persistence
import RDPDomain
import UniformTypeIdentifiers

private let rdpDocumentType = UTType(filenameExtension: "rdp")
    ?? UTType(importedAs: "com.microsoft.rdp")

@MainActor
final class ConnectionLibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onEditorClosed: (() -> Void)?
    private let database: ProfileDatabase
    private let credentialStore: CredentialStoring
    private let diagnostics: DiagnosticTimeline
    private let settings: ApplicationSettingsStore
    private var profiles: [ConnectionProfile] = []
    private var sessionWindows: [UUID: SessionWindowController] = [:]
    private var diagnosticsWindowController: DiagnosticsWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var editorWindowController: ProfileEditorWindowController?
    private var reloadGeneration: UInt64 = 0
    private var profilesBeingDeleted = Set<UUID>()

    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: NSLocalizedString("Connect", comment: "connect"), target: nil, action: nil)

    init(database: ProfileDatabase, credentialStore: CredentialStoring, diagnostics: DiagnosticTimeline, settings: ApplicationSettingsStore) {
        self.database = database
        self.credentialStore = credentialStore
        self.diagnostics = diagnostics
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = NSLocalizedString("Remote Desktop Connections", comment: "main title")
        window.minSize = NSSize(width: 720, height: 440)
        window.center()
        super.init(window: window)
        buildInterface()
        Task { await reload() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let addButton = iconButton(symbol: "plus", tooltip: NSLocalizedString("New Connection", comment: "new"), action: #selector(addConnection))
        let editButton = iconButton(symbol: "pencil", tooltip: NSLocalizedString("Edit Connection", comment: "edit"), action: #selector(editConnection))
        let duplicateButton = iconButton(symbol: "plus.square.on.square", tooltip: NSLocalizedString("Duplicate Connection", comment: "duplicate"), action: #selector(duplicateConnection))
        let deleteButton = iconButton(symbol: "trash", tooltip: NSLocalizedString("Delete Connection", comment: "delete"), action: #selector(deleteConnection))
        let importButton = iconButton(symbol: "square.and.arrow.down", tooltip: NSLocalizedString("Import RDP File", comment: "import rdp"), action: #selector(importRDPFile))
        let exportButton = iconButton(symbol: "square.and.arrow.up", tooltip: NSLocalizedString("Export RDP File", comment: "export rdp"), action: #selector(exportRDPFile))
        let diagnosticsButton = iconButton(symbol: "waveform.path.ecg", tooltip: NSLocalizedString("Diagnostics", comment: "diagnostics"), action: #selector(showDiagnostics))
        let backupButton = iconButton(symbol: "archivebox", tooltip: NSLocalizedString("Back Up Connections", comment: "backup profiles"), action: #selector(backupProfiles))
        let restoreButton = iconButton(symbol: "arrow.counterclockwise", tooltip: NSLocalizedString("Restore Connections", comment: "restore profiles"), action: #selector(restoreProfiles))
        let settingsButton = iconButton(symbol: "gearshape", tooltip: NSLocalizedString("Settings", comment: "settings"), action: #selector(showSettings))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.placeholderString = NSLocalizedString("Search connections", comment: "search placeholder")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        toolbar.addArrangedSubview(addButton)
        toolbar.addArrangedSubview(editButton)
        toolbar.addArrangedSubview(duplicateButton)
        toolbar.addArrangedSubview(deleteButton)
        toolbar.addArrangedSubview(importButton)
        toolbar.addArrangedSubview(exportButton)
        toolbar.addArrangedSubview(diagnosticsButton)
        toolbar.addArrangedSubview(backupButton)
        toolbar.addArrangedSubview(restoreButton)
        toolbar.addArrangedSubview(settingsButton)
        toolbar.addArrangedSubview(spacer)
        toolbar.addArrangedSubview(searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("connection"))
        column.title = NSLocalizedString("Connections", comment: "connection list")
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 54
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(connectSelected)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 12
        bottom.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        connectButton.target = self
        connectButton.action = #selector(connectSelected)
        connectButton.keyEquivalent = "\r"
        bottom.addArrangedSubview(statusLabel)
        bottom.addArrangedSubview(NSView())
        bottom.addArrangedSubview(connectButton)

        [toolbar, scroll, bottom].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        updateSelection()
    }

    private func iconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        return button
    }

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profiles.indices.contains(row) else { return nil }
        let profile = profiles[row]
        let identifier = NSUserInterfaceItemIdentifier("ConnectionCell")
        let cell: NSTableCellView
        let title: NSTextField
        let detail: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           reused.subviews.count >= 2,
           let existingTitle = reused.subviews[0] as? NSTextField,
           let existingDetail = reused.subviews[1] as? NSTextField {
            cell = reused; title = existingTitle; detail = existingDetail
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            title = NSTextField(labelWithString: "")
            detail = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 13, weight: .medium)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            title.translatesAutoresizingMaskIntoConstraints = false
            detail.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(title); cell.addSubview(detail)
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3)
            ])
        }
        title.stringValue = (profile.isFavorite ? "★ " : "") + profile.name
        detail.stringValue = "\(profile.target.endpoint.host):\(profile.target.endpoint.port)  •  \(routeLabel(profile.route))"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    func controlTextDidChange(_ obj: Notification) { Task { await reload() } }

    private func updateSelection() {
        let selected = tableView.selectedRow >= 0 && tableView.selectedRow < profiles.count
        connectButton.isEnabled = selected
        statusLabel.stringValue = selected ? "\(profiles[tableView.selectedRow].target.endpoint.host):\(profiles[tableView.selectedRow].target.endpoint.port)" : NSLocalizedString("Select a saved connection or create a new one.", comment: "empty selection")
    }

    private func reload(selecting id: UUID? = nil) async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let search = searchField.stringValue
        do {
            let loadedProfiles = try await database.profiles(search: search)
            guard generation == reloadGeneration else { return }
            profiles = loadedProfiles
            tableView.reloadData()
            if let id, let row = profiles.firstIndex(where: { $0.id == id }) { tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            updateSelection()
        } catch {
            guard generation == reloadGeneration else { return }
            present(error)
        }
    }

    @objc private func addConnection() {
        let defaults = settings.load()
        let profile = ConnectionProfile(
            name: NSLocalizedString("New Connection", comment: "default name"),
            target: TargetIdentity(endpoint: Endpoint(host: "", port: 3389)),
            display: DisplayConfiguration(scaleMode: defaults.defaultScaleMode),
            redirection: RedirectionPolicy.defaults(for: defaults.defaultRedirectionPreset),
            reconnect: ReconnectPolicy(maximumAttempts: defaults.defaultReconnectAttempts)
        )
        presentEditor(profile)
    }

    @objc private func editConnection() { guard let profile = selectedProfile else { return }; presentEditor(profile) }

    @objc private func duplicateConnection() {
        guard var profile = selectedProfile else { return }
        profile.id = UUID()
        profile.name += NSLocalizedString(" Copy", comment: "duplicate suffix")
        profile.credentialReference = nil
        switch profile.route {
        case let .socks5(proxy):
            var copy = proxy; copy.credentialReference = nil; profile.route = .socks5(copy)
        case let .httpConnect(proxy, tls):
            var copy = proxy; copy.credentialReference = nil; profile.route = .httpConnect(proxy: copy, tls: tls)
        case let .rdGateway(gateway):
            var copy = gateway; copy.credentialReference = nil; profile.route = .rdGateway(copy)
        case .direct: break
        }
        profile.createdAt = Date(); profile.updatedAt = Date(); profile.lastConnectedAt = nil
        presentEditor(profile)
    }

    @objc private func deleteConnection() {
        guard let profile = selectedProfile else { return }
        guard !profilesBeingDeleted.contains(profile.id) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("Delete “%@”?", comment: "delete title"), profile.name)
        alert.informativeText = NSLocalizedString("The saved profile and its stored credentials will be removed.", comment: "delete detail")
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "delete"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profilesBeingDeleted.insert(profile.id)
        Task {
            defer { profilesBeingDeleted.remove(profile.id) }
            do {
                let cleanupFailures = try await ProfileDeletionTransaction.commit(
                    credentialStore: credentialStore,
                    deleteProfile: {
                        try await self.database.deleteAndReturnUnreferencedCredentialReferences(
                            id: profile.id
                        )
                    }
                )
                for failure in cleanupFailures {
                    await diagnostics.record(DiagnosticEvent(
                        level: .warning,
                        category: .security,
                        code: "DELETED_PROFILE_CREDENTIAL_CLEANUP_FAILED",
                        message: "A Keychain item could not be removed after its profile was deleted.",
                        fields: [
                            "itemID": .privateText(failure.reference.id.uuidString),
                            "errorDetail": .privateText(failure.message)
                        ]
                    ))
                }
                await reload()
                if !cleanupFailures.isEmpty {
                    statusLabel.stringValue = NSLocalizedString(
                        "Connection deleted, but one or more Keychain items could not be removed. Review Diagnostics.",
                        comment: "credential cleanup warning"
                    )
                }
            } catch { present(error) }
        }
    }

    @objc private func connectSelected() {
        guard var storedProfile = selectedProfile else { return }
        let connectedAt = Date()
        storedProfile.lastConnectedAt = connectedAt; storedProfile.updatedAt = connectedAt
        Task {
            do { try await database.markConnected(id: storedProfile.id, at: connectedAt) }
            catch {
                await diagnostics.record(DiagnosticEvent(
                    level: .warning,
                    category: .persistence,
                    code: "LAST_CONNECTED_UPDATE_FAILED",
                    message: "The profile's last-connected timestamp could not be updated.",
                    fields: ["errorDetail": .privateText(error.localizedDescription)]
                ))
            }
        }
        let profile = settings.policy.applying(to: storedProfile)
        let sessionID = UUID()
        let controller = SessionWindowController(
            sessionID: sessionID, profile: profile, credentialStore: credentialStore, diagnostics: diagnostics,
            automaticReconnectEnabled: settings.load().automaticReconnectEnabled,
            enterprisePolicy: settings.policy,
            onProfileUpdate: { [weak self] request in
                guard let self else { throw CancellationError() }
                try await self.persistProfileSave(request, requiresExisting: true)
            }
        ) { [weak self] id in self?.sessionWindows.removeValue(forKey: id) }
        sessionWindows[sessionID] = controller
        controller.showWindow(nil)
        controller.connect()
    }

    @objc private func importRDPFile() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [rdpDocumentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                try self.importRDPFile(at: url)
            } catch { self.present(error) }
        }
    }

    func importRDPFile(at url: URL) throws {
        let profile = try RDPFileCodec.decode(
            contentsOf: url,
            suggestedName: url.deletingPathExtension().lastPathComponent
        )
        presentEditor(profile)
    }

    var canPresentConnectionEditor: Bool { editorWindowController == nil }

    @objc private func exportRDPFile() {
        guard let window, let profile = selectedProfile else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [rdpDocumentType]
        panel.nameFieldStringValue = profile.name + ".rdp"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do { try RDPFileCodec.encode(profile).write(to: url, options: .atomic) }
            catch { self.present(error) }
        }
    }

    @objc private func showDiagnostics() {
        let controller = diagnosticsWindowController ?? DiagnosticsWindowController(
            diagnostics: diagnostics,
            allowsPrivateExport: settings.policy.allowsPrivateDiagnosticExport
        )
        diagnosticsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        let controller = settingsWindowController ?? SettingsWindowController(store: settings)
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func backupProfiles() {
        Task {
            do {
                let data = try await database.exportProfiles()
                guard let window else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "RemoteDesktop-Profiles.json"
                panel.beginSheetModal(for: window) { [weak self] response in
                    guard response == .OK, let self, let url = panel.url else { return }
                    do { try data.write(to: url, options: .atomic) }
                    catch { self.present(error) }
                }
            } catch { present(error) }
        }
    }

    @objc private func restoreProfiles() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            Task {
                do {
                    let restore = try await CredentialCleanupTransaction.commit(
                        credentialStore: self.credentialStore
                    ) {
                        let imported = try await self.database
                            .importProfilesAndReturnUnreferencedCredentialReferences(contentsOf: url)
                        return (
                            result: imported.importedCount,
                            referencesToDelete: imported.unreferencedCredentialReferences
                        )
                    }
                    for failure in restore.cleanupFailures {
                        await self.diagnostics.record(DiagnosticEvent(
                            level: .warning,
                            category: .security,
                            code: "RESTORE_CREDENTIAL_CLEANUP_FAILED",
                            message: "An unreferenced Keychain item could not be removed after profile restore.",
                            fields: [
                                "itemID": .privateText(failure.reference.id.uuidString),
                                "errorDetail": .privateText(failure.message)
                            ]
                        ))
                    }
                    await self.reload()
                    self.statusLabel.stringValue = String(
                        format: NSLocalizedString("Restored %d connections. Credentials and shared folders must be entered or selected again.", comment: "restore result"),
                        restore.result
                    )
                } catch { self.present(error) }
            }
        }
    }

    private var selectedProfile: ConnectionProfile? {
        let row = tableView.selectedRow
        return profiles.indices.contains(row) ? profiles[row] : nil
    }

    private func presentEditor(_ profile: ConnectionProfile) {
        guard editorWindowController == nil else {
            editorWindowController?.window?.makeKeyAndOrderFront(nil)
            return
        }
        let editor = ProfileEditorWindowController(
            profile: profile,
            credentialStore: credentialStore,
            enterprisePolicy: settings.policy
        )
        guard let parent = window, let editorWindow = editor.window else { return }
        editorWindowController = editor
        editor.onCancel = { [weak self] in
            self?.editorWindowController = nil
            self?.onEditorClosed?()
        }
        editor.onSave = { [weak self] request in
            guard let self else { throw CancellationError() }
            try await self.persistProfileSave(request)
            self.editorWindowController = nil
            await self.reload(selecting: request.profile.id)
            DispatchQueue.main.async { [weak self] in self?.onEditorClosed?() }
        }
        parent.beginSheet(editorWindow)
    }

    private func persistProfileSave(
        _ request: ProfileSaveRequest,
        requiresExisting: Bool = false
    ) async throws {
        let existingProfile = try await database.profile(id: request.profile.id)
        if requiresExisting, existingProfile == nil {
            throw ProfileDatabaseError.profileNotFound(request.profile.id)
        }
        var proposedProfile = request.profile
        if let existingProfile {
            switch request.scope {
            case .fullProfile:
                if let baseProfile = request.baseProfile,
                   !profilesMatchIgnoringConnectionDates(existingProfile, baseProfile) {
                    throw ProfileDatabaseError.staleProfile(existingProfile.id)
                }
                proposedProfile.createdAt = existingProfile.createdAt
                if let existingConnected = existingProfile.lastConnectedAt {
                    if let proposedConnected = proposedProfile.lastConnectedAt {
                        proposedProfile.lastConnectedAt = max(existingConnected, proposedConnected)
                    } else {
                        proposedProfile.lastConnectedAt = existingConnected
                    }
                }
            case .credentialsOnly:
                guard let baseProfile = request.baseProfile,
                      credentialTopologyMatches(existingProfile, baseProfile) else {
                    throw ProfileDatabaseError.staleProfile(existingProfile.id)
                }
                proposedProfile = try mergeCredentialChanges(
                    from: request.profile,
                    into: existingProfile,
                    writes: request.credentialWrites
                )
            }
        }
        let storedProfile = settings.policy.applyingForStorage(
            to: proposedProfile,
            preserving: existingProfile,
            managedFieldChanges: request.managedFieldChanges
        )
        let retainedReferences = storedProfile.credentialReferences
        let constrainedRequest = ProfileSaveRequest(
            profile: storedProfile,
            credentialWrites: request.credentialWrites.filter { retainedReferences.contains($0.reference) },
            obsoleteCredentialReferences: request.obsoleteCredentialReferences.union(
                request.profile.credentialReferences.subtracting(retainedReferences)
            ),
            managedFieldChanges: request.managedFieldChanges,
            scope: request.scope,
            baseProfile: request.baseProfile
        )
        let cleanupFailures: [CredentialCleanupFailure]
        do {
            cleanupFailures = try await CredentialTransaction.commit(
                constrainedRequest,
                credentialStore: credentialStore,
                persistProfile: {
                    try await self.database.saveAndReturnUnreferencedCredentialReferences(
                        storedProfile,
                        expectedToExist: existingProfile != nil,
                        expectedUpdatedAt: existingProfile?.updatedAt,
                        cleanupCandidates: constrainedRequest.obsoleteCredentialReferences
                    )
                }
            )
        } catch let rollbackError as CredentialRollbackError {
            for failure in rollbackError.cleanupFailures {
                await diagnostics.record(DiagnosticEvent(
                    level: .error,
                    category: .security,
                    code: "CREDENTIAL_ROLLBACK_DELETE_FAILED",
                    message: "A newly written Keychain item could not be removed after profile persistence failed.",
                    fields: [
                        "itemID": .privateText(failure.reference.id.uuidString),
                        "errorDetail": .privateText(failure.message),
                        "persistenceError": .privateText(rollbackError.persistenceMessage)
                    ]
                ))
            }
            throw rollbackError
        }
        for failure in cleanupFailures {
            await diagnostics.record(DiagnosticEvent(
                level: .warning,
                category: .security,
                code: "OBSOLETE_CREDENTIAL_DELETE_FAILED",
                message: "An obsolete Keychain item could not be removed after a profile update.",
                fields: [
                    "itemID": .privateText(failure.reference.id.uuidString),
                    "errorDetail": .privateText(failure.message)
                ]
            ))
        }
    }

    private func profilesMatchIgnoringConnectionDates(
        _ lhs: ConnectionProfile,
        _ rhs: ConnectionProfile
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.updatedAt = Date(timeIntervalSince1970: 0)
        rhs.updatedAt = lhs.updatedAt
        lhs.lastConnectedAt = nil
        rhs.lastConnectedAt = nil
        return lhs == rhs
    }

    private func credentialTopologyMatches(
        _ lhs: ConnectionProfile,
        _ rhs: ConnectionProfile
    ) -> Bool {
        guard lhs.id == rhs.id, lhs.target == rhs.target,
              lhs.credentialReference == rhs.credentialReference else { return false }
        switch (lhs.route, rhs.route) {
        case (.direct, .direct):
            return true
        case let (.socks5(lhsProxy), .socks5(rhsProxy)):
            return lhsProxy == rhsProxy
        case let (.httpConnect(lhsProxy, lhsTLS), .httpConnect(rhsProxy, rhsTLS)):
            return lhsProxy == rhsProxy && lhsTLS == rhsTLS
        case let (.rdGateway(lhsGateway), .rdGateway(rhsGateway)):
            return lhsGateway == rhsGateway
        default:
            return false
        }
    }

    private func mergeCredentialChanges(
        from proposed: ConnectionProfile,
        into existing: ConnectionProfile,
        writes: [CredentialWrite]
    ) throws -> ConnectionProfile {
        guard proposed.target == existing.target else {
            throw ProfileDatabaseError.staleProfile(existing.id)
        }
        var merged = existing
        let changedKinds = Set(writes.map { $0.reference.kind })
        if changedKinds.contains(.target) {
            merged.usernameHint = proposed.usernameHint
            merged.domainHint = proposed.domainHint
            merged.credentialReference = proposed.credentialReference
        }
        if changedKinds.contains(.proxy) {
            switch (existing.route, proposed.route) {
            case let (.socks5(current), .socks5(updated))
                where current.endpoint == updated.endpoint &&
                    current.resolvesTargetName == updated.resolvesTargetName:
                var proxy = current
                proxy.usernameHint = updated.usernameHint
                proxy.credentialReference = updated.credentialReference
                merged.route = .socks5(proxy)
            case let (.httpConnect(current, currentTLS), .httpConnect(updated, updatedTLS))
                where current.endpoint == updated.endpoint &&
                    current.resolvesTargetName == updated.resolvesTargetName &&
                    currentTLS == updatedTLS:
                var proxy = current
                proxy.usernameHint = updated.usernameHint
                proxy.credentialReference = updated.credentialReference
                merged.route = .httpConnect(proxy: proxy, tls: currentTLS)
            default:
                throw ProfileDatabaseError.staleProfile(existing.id)
            }
        }
        if changedKinds.contains(.gateway) {
            guard case let .rdGateway(current) = existing.route,
                  case let .rdGateway(updated) = proposed.route,
                  current.endpoint == updated.endpoint,
                  current.transport == updated.transport else {
                throw ProfileDatabaseError.staleProfile(existing.id)
            }
            var gateway = current
            gateway.credentialReference = updated.credentialReference
            merged.route = .rdGateway(gateway)
        }
        merged.updatedAt = proposed.updatedAt
        return merged
    }

    private func routeLabel(_ route: RouteConfiguration) -> String {
        switch route {
        case .direct: return NSLocalizedString("Direct", comment: "direct route")
        case .socks5: return "SOCKS5"
        case let .httpConnect(_, tls): return tls ? "HTTPS CONNECT" : "HTTP CONNECT"
        case .rdGateway: return "RD Gateway"
        }
    }

    private func present(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }
}
