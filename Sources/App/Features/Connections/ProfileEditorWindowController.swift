import AppKit
import Persistence
import RDPDomain
import RDPTransport

@MainActor
final class ProfileEditorWindowController: NSWindowController {
    var onSave: ((ProfileSaveRequest) async throws -> Void)?
    var onCancel: (() -> Void)?

    private var profile: ConnectionProfile
    private let credentialStore: CredentialStoring
    private let enterprisePolicy: EnterprisePolicy
    private let tabView = NSTabView()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let usernameField = NSTextField()
    private let domainField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let saveTargetCredentialButton = NSButton(
        checkboxWithTitle: NSLocalizedString("Save in Keychain", comment: "save target credential"),
        target: nil,
        action: nil
    )
    private let tagsField = NSTextField()
    private let favoriteButton = NSButton(checkboxWithTitle: NSLocalizedString("Favorite", comment: "favorite"), target: nil, action: nil)
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let scalePopup = NSPopUpButton()
    private let allDisplaysButton = NSButton(checkboxWithTitle: NSLocalizedString("Use all displays", comment: "all displays"), target: nil, action: nil)
    private let keyboardPopup = NSPopUpButton()
    private let routePopup = NSPopUpButton()
    private let proxyHostField = NSTextField()
    private let proxyPortField = NSTextField()
    private let proxyUsernameField = NSTextField()
    private let proxyPasswordField = NSSecureTextField()
    private let saveRouteCredentialButton = NSButton(
        checkboxWithTitle: NSLocalizedString("Save in Keychain", comment: "save route credential"),
        target: nil,
        action: nil
    )
    private let gatewayDomainField = NSTextField()
    private let clipboardTextButton = NSButton(checkboxWithTitle: NSLocalizedString("Text clipboard", comment: "clipboard text"), target: nil, action: nil)
    private let clipboardImagesButton = NSButton(checkboxWithTitle: NSLocalizedString("Image clipboard", comment: "clipboard images"), target: nil, action: nil)
    private let clipboardFilesButton = NSButton(checkboxWithTitle: NSLocalizedString("File clipboard", comment: "clipboard files"), target: nil, action: nil)
    private let audioButton = NSButton(checkboxWithTitle: NSLocalizedString("Remote audio playback", comment: "audio"), target: nil, action: nil)
    private let microphoneButton = NSButton(checkboxWithTitle: NSLocalizedString("Microphone redirection", comment: "microphone"), target: nil, action: nil)
    private let folderSummary = NSTextField(wrappingLabelWithString: "")
    private var sharedFolders: [SharedFolderBookmark]
    private let printersButton = NSButton(checkboxWithTitle: NSLocalizedString("Printer redirection", comment: "printers"), target: nil, action: nil)
    private let camerasButton = NSButton(checkboxWithTitle: NSLocalizedString("Camera redirection", comment: "cameras"), target: nil, action: nil)
    private let smartCardsButton = NSButton(checkboxWithTitle: NSLocalizedString("Smart-card redirection", comment: "smart cards"), target: nil, action: nil)
    private let redirectionPresetPopup = NSPopUpButton()
    private let chooseFoldersButton = NSButton(
        title: NSLocalizedString("Choose Folders…", comment: "choose folders"),
        target: nil,
        action: nil
    )
    private let clearFoldersButton = NSButton(
        title: NSLocalizedString("Remove All", comment: "remove folders"),
        target: nil,
        action: nil
    )
    private let certificateNameField = NSTextField()
    private let reconnectAttemptsField = NSTextField()
    private let routeTestButton = NSButton(title: NSLocalizedString("Test Connection", comment: "test route"), target: nil, action: nil)
    private let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "cancel"), target: nil, action: nil)
    private let saveButton = NSButton(title: NSLocalizedString("Save", comment: "save"), target: nil, action: nil)
    private var routeTestTask: Task<Void, Never>?
    private var routeTestGeneration: UInt64 = 0
    private var loadedCredentialMaterials: [CredentialReference: CredentialMaterial] = [:]
    private var isSaving = false

    init(
        profile: ConnectionProfile,
        credentialStore: CredentialStoring,
        enterprisePolicy: EnterprisePolicy = .unrestricted
    ) {
        self.profile = profile
        self.credentialStore = credentialStore
        self.enterprisePolicy = enterprisePolicy
        self.sharedFolders = profile.redirection.sharedFolders
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 550),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = NSLocalizedString("Connection Settings", comment: "editor title")
        super.init(window: window)
        buildInterface()
        loadProfile()
        applyEnterprisePolicy()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(tab(title: NSLocalizedString("General", comment: "general"), rows: [
            row(NSLocalizedString("Name", comment: "name"), nameField),
            row(NSLocalizedString("Host", comment: "host"), hostField),
            row(NSLocalizedString("Port", comment: "port"), portField),
            row(NSLocalizedString("Username", comment: "username"), usernameField),
            row(NSLocalizedString("Domain", comment: "domain"), domainField),
            row(NSLocalizedString("Password", comment: "password"), passwordField),
            saveTargetCredentialButton,
            row(NSLocalizedString("Tags", comment: "tags"), tagsField), favoriteButton
        ]))
        scalePopup.addItems(withTitles: [NSLocalizedString("Fit window", comment: "fit"), NSLocalizedString("Actual size", comment: "actual"), NSLocalizedString("Dynamic resolution", comment: "dynamic")])
        keyboardPopup.addItems(withTitles: [NSLocalizedString("Mac shortcuts first", comment: "mac keyboard"), NSLocalizedString("Windows shortcuts first", comment: "windows keyboard")])
        portField.placeholderString = "3389"
        portField.toolTip = NSLocalizedString("Enter a port between 1 and 65535 using digits only.", comment: "port input help")
        proxyPortField.toolTip = portField.toolTip
        tabView.addTabViewItem(tab(title: NSLocalizedString("Display", comment: "display"), rows: [
            row(NSLocalizedString("Width", comment: "width"), widthField),
            row(NSLocalizedString("Height", comment: "height"), heightField),
            row(NSLocalizedString("Scaling", comment: "scaling"), scalePopup),
            row(NSLocalizedString("Keyboard", comment: "keyboard"), keyboardPopup), allDisplaysButton
        ]))
        routePopup.addItems(withTitles: ["Direct", "SOCKS5", "HTTP CONNECT", "HTTPS CONNECT", "RD Gateway"] )
        routePopup.target = self; routePopup.action = #selector(routeChanged)
        routeTestButton.target = self; routeTestButton.action = #selector(testConnectionPath)
        tabView.addTabViewItem(tab(title: NSLocalizedString("Network", comment: "network"), rows: [
            row(NSLocalizedString("Route", comment: "route"), routePopup),
            row(NSLocalizedString("Proxy / gateway host", comment: "proxy host"), proxyHostField),
            row(NSLocalizedString("Proxy / gateway port", comment: "proxy port"), proxyPortField),
            row(NSLocalizedString("Proxy / gateway username", comment: "proxy user"), proxyUsernameField),
            row(NSLocalizedString("Gateway domain", comment: "gateway domain"), gatewayDomainField),
            row(NSLocalizedString("Proxy / gateway password", comment: "proxy password"), proxyPasswordField),
            saveRouteCredentialButton,
            routeTestButton
        ]))
        chooseFoldersButton.target = self
        chooseFoldersButton.action = #selector(chooseFolders)
        clearFoldersButton.target = self
        clearFoldersButton.action = #selector(clearFolders)
        let folderButtons = NSStackView(views: [chooseFoldersButton, clearFoldersButton])
        folderButtons.orientation = .horizontal; folderButtons.spacing = 8
        folderSummary.maximumNumberOfLines = 3
        folderSummary.textColor = .secondaryLabelColor
        folderSummary.widthAnchor.constraint(equalToConstant: 500).isActive = true
        redirectionPresetPopup.addItems(withTitles: [
            NSLocalizedString("Secure", comment: "secure preset"),
            NSLocalizedString("Standard", comment: "standard preset"),
            NSLocalizedString("Complete", comment: "complete preset")
        ])
        redirectionPresetPopup.target = self
        redirectionPresetPopup.action = #selector(redirectionPresetChanged)
        camerasButton.isEnabled = false
        camerasButton.toolTip = NSLocalizedString("Camera redirection is not available in this build.", comment: "camera unavailable")
        tabView.addTabViewItem(tab(title: NSLocalizedString("Resources", comment: "resources"), rows: [
            row(NSLocalizedString("Policy", comment: "redirection policy"), redirectionPresetPopup),
            clipboardTextButton, clipboardImagesButton, clipboardFilesButton, audioButton, microphoneButton,
            note(NSLocalizedString("Shared folders", comment: "shared folders")), folderSummary, folderButtons,
            printersButton, camerasButton, smartCardsButton
        ]))
        tabView.addTabViewItem(tab(title: NSLocalizedString("Security", comment: "security"), rows: [
            row(NSLocalizedString("Certificate name", comment: "certificate name"), certificateNameField),
            note(NSLocalizedString("TLS and NLA are always enabled. Unknown or changed certificates require an explicit decision.", comment: "security note"))
        ]))
        tabView.addTabViewItem(tab(title: NSLocalizedString("Advanced", comment: "advanced"), rows: [
            row(NSLocalizedString("Reconnect attempts", comment: "reconnect attempts"), reconnectAttemptsField),
            note(NSLocalizedString("Automatic retries use bounded exponential backoff and never loop on authentication failures.", comment: "reconnect note"))
        ]))

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal; buttons.spacing = 8; buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView); content.addSubview(buttons)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            tabView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    private func tab(title: String, rows: [NSView]) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title); item.label = title
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        item.view = stack
        return item
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let stack = NSStackView(views: [labelField, control]); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 12
        return stack
    }

    private func note(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor; field.maximumNumberOfLines = 3
        field.widthAnchor.constraint(equalToConstant: 500).isActive = true
        return field
    }

    private func loadProfile() {
        nameField.stringValue = profile.name
        hostField.stringValue = profile.target.endpoint.host
        portField.stringValue = String(profile.target.endpoint.port)
        usernameField.stringValue = profile.usernameHint
        domainField.stringValue = profile.domainHint
        tagsField.stringValue = profile.tags.joined(separator: ", ")
        favoriteButton.state = profile.isFavorite ? .on : .off
        widthField.integerValue = Int(profile.display.width); heightField.integerValue = Int(profile.display.height)
        scalePopup.selectItem(at: profile.display.scaleMode == .fit ? 0 : profile.display.scaleMode == .actualSize ? 1 : 2)
        keyboardPopup.selectItem(at: profile.display.keyboardMode == .macPreferred ? 0 : 1)
        allDisplaysButton.state = profile.display.useAllDisplays ? .on : .off
        certificateNameField.stringValue = profile.target.certificateName
        reconnectAttemptsField.integerValue = Int(profile.reconnect.maximumAttempts)
        clipboardTextButton.state = profile.redirection.clipboardText ? .on : .off
        clipboardImagesButton.state = profile.redirection.clipboardImages ? .on : .off
        clipboardFilesButton.state = profile.redirection.clipboardFiles ? .on : .off
        audioButton.state = profile.redirection.audioPlayback ? .on : .off
        microphoneButton.state = profile.redirection.microphone ? .on : .off
        refreshFolderSummary()
        printersButton.state = profile.redirection.printers ? .on : .off
        camerasButton.state = profile.redirection.cameras ? .on : .off
        smartCardsButton.state = profile.redirection.smartCards ? .on : .off
        redirectionPresetPopup.selectItem(at: profile.redirection.preset == .secure ? 0 : profile.redirection.preset == .standard ? 1 : 2)
        saveTargetCredentialButton.state = .on
        if enterprisePolicy.allowsCredentialSaving, let reference = profile.credentialReference {
            if loadCredential(reference) != nil {
                passwordField.placeholderString = NSLocalizedString("Saved in Keychain", comment: "saved credential placeholder")
            }
        }
        switch profile.route {
        case .direct:
            routePopup.selectItem(at: 0)
            saveRouteCredentialButton.state = .on
        case let .socks5(proxy): routePopup.selectItem(at: 1); loadProxy(proxy, tls: false)
        case let .httpConnect(proxy, tls): routePopup.selectItem(at: tls ? 3 : 2); loadProxy(proxy, tls: tls)
        case let .rdGateway(gateway):
            routePopup.selectItem(at: 4); proxyHostField.stringValue = gateway.endpoint.host; proxyPortField.stringValue = String(gateway.endpoint.port)
            saveRouteCredentialButton.state = .on
            if enterprisePolicy.allowsCredentialSaving, let reference = gateway.credentialReference {
                if let credential = loadCredential(reference) {
                    proxyPasswordField.placeholderString = NSLocalizedString("Saved in Keychain", comment: "saved credential placeholder")
                    proxyUsernameField.stringValue = credential.username
                    gatewayDomainField.stringValue = credential.domain
                }
            }
        }
        routeChanged()
    }

    private func loadProxy(_ proxy: ProxyConfiguration, tls: Bool) {
        proxyHostField.stringValue = proxy.endpoint.host; proxyPortField.stringValue = String(proxy.endpoint.port)
        proxyUsernameField.stringValue = proxy.usernameHint
        saveRouteCredentialButton.state = .on
        if enterprisePolicy.allowsCredentialSaving, let reference = proxy.credentialReference {
            if let credential = loadCredential(reference) {
                proxyPasswordField.placeholderString = NSLocalizedString("Saved in Keychain", comment: "saved credential placeholder")
                proxyUsernameField.stringValue = credential.username
            }
        }
    }

    private func loadCredential(_ reference: CredentialReference) -> CredentialMaterial? {
        do {
            guard let material = try credentialStore.load(reference: reference) else { return nil }
            loadedCredentialMaterials[reference] = material
            return material
        } catch {
            return nil
        }
    }

    @objc private func routeChanged() {
        let enabled = routePopup.indexOfSelectedItem != 0
        [proxyHostField, proxyPortField, proxyUsernameField, proxyPasswordField].forEach { $0.isEnabled = enabled }
        saveRouteCredentialButton.isEnabled = enabled && enterprisePolicy.allowsCredentialSaving
        gatewayDomainField.isEnabled = routePopup.indexOfSelectedItem == 4
        let credentialKind: CredentialReference.Kind = routePopup.indexOfSelectedItem == 4 ? .gateway : .proxy
        if let reference = existingCredentialReference(for: credentialKind),
           loadedCredentialMaterials[reference] != nil {
            proxyPasswordField.placeholderString = NSLocalizedString("Saved in Keychain", comment: "saved credential placeholder")
        } else {
            proxyPasswordField.placeholderString = nil
        }
        if enabled && proxyPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            proxyPortField.stringValue = String(routePopup.indexOfSelectedItem == 4 ? 443 : (routePopup.indexOfSelectedItem == 1 ? 1080 : 8080))
        }
    }

    @objc private func cancel() {
        guard !isSaving else { return }
        routeTestGeneration &+= 1
        routeTestTask?.cancel()
        routeTestTask = nil
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        onCancel?()
    }

    @objc private func save() {
        guard !isSaving else { return }
        do {
            var updated = profile
            var credentialWrites: [CredentialWrite] = []
            updated.name = nameField.stringValue
            let port = try validPort(portField, name: "target")
            let certificate = certificateNameField.stringValue.isEmpty ? hostField.stringValue : certificateNameField.stringValue
            updated.target = TargetIdentity(endpoint: Endpoint(host: hostField.stringValue, port: port), certificateName: certificate)
            updated.usernameHint = usernameField.stringValue; updated.domainHint = domainField.stringValue
            updated.tags = tagsField.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            updated.isFavorite = favoriteButton.state == .on; updated.updatedAt = Date()
            updated.display = DisplayConfiguration(
                width: UInt32(clamping: widthField.integerValue),
                height: UInt32(clamping: heightField.integerValue),
                scaleMode: scalePopup.indexOfSelectedItem == 0 ? .fit : scalePopup.indexOfSelectedItem == 1 ? .actualSize : .dynamicResolution,
                useAllDisplays: allDisplaysButton.state == .on, keyboardMode: keyboardPopup.indexOfSelectedItem == 0 ? .macPreferred : .windowsPreferred
            )
            updated.redirection = RedirectionPolicy(
                preset: selectedRedirectionPreset, clipboardText: clipboardTextButton.state == .on, clipboardImages: clipboardImagesButton.state == .on,
                clipboardFiles: clipboardFilesButton.state == .on, audioPlayback: audioButton.state == .on, microphone: microphoneButton.state == .on,
                drivePaths: [], sharedFolders: sharedFolders, printers: printersButton.state == .on,
                cameras: camerasButton.state == .on, smartCards: smartCardsButton.state == .on
            )
            updated.reconnect.maximumAttempts = UInt8(clamping: reconnectAttemptsField.integerValue)
            let targetCredential = try credentialWrite(
                kind: .target,
                username: updated.usernameHint,
                domain: updated.domainHint,
                password: passwordField.stringValue,
                shouldStore: saveTargetCredentialButton.state == .on,
                existingReference: profile.credentialReference
            )
            updated.credentialReference = targetCredential.reference
            if let write = targetCredential.write { credentialWrites.append(write) }
            let routeResult = try buildRouteForSave()
            updated.route = routeResult.route
            credentialWrites.append(contentsOf: routeResult.writes)
            updated = try updated.validated()
            let retained = updated.credentialReferences
            let effectiveOriginal = enterprisePolicy.applying(to: profile)
            let effectiveUpdated = enterprisePolicy.applying(to: updated)
            var managedFieldChanges = Set<ManagedProfileField>()
            if enterprisePolicy.maximumReconnectAttempts != nil,
               effectiveUpdated.reconnect != effectiveOriginal.reconnect {
                managedFieldChanges.insert(.reconnect)
            }
            if enterprisePolicy.maximumRedirectionPreset != nil,
               effectiveUpdated.redirection != effectiveOriginal.redirection {
                managedFieldChanges.insert(.redirection)
            }
            let request = ProfileSaveRequest(
                profile: updated,
                credentialWrites: credentialWrites,
                obsoleteCredentialReferences: profile.credentialReferences.subtracting(retained),
                managedFieldChanges: managedFieldChanges,
                baseProfile: profile
            )
            setSaving(true)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.onSave?(request)
                    self.profile = updated
                    if let window = self.window, let parent = window.sheetParent { parent.endSheet(window) }
                } catch {
                    self.setSaving(false)
                    guard let window = self.window else { return }
                    _ = await NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        } catch {
            guard let window else { return }; NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    private func buildRouteForSave() throws -> (route: RouteConfiguration, writes: [CredentialWrite]) {
        let index = routePopup.indexOfSelectedItem
        guard index != 0 else { return (.direct, []) }
        let endpoint = Endpoint(host: proxyHostField.stringValue, port: try validPort(proxyPortField, name: index == 4 ? "gateway" : "proxy"))
        if index == 4 {
            let credential = try credentialWrite(
                kind: .gateway,
                username: proxyUsernameField.stringValue,
                domain: gatewayDomainField.stringValue,
                password: proxyPasswordField.stringValue,
                shouldStore: saveRouteCredentialButton.state == .on,
                existingReference: existingCredentialReference(for: .gateway)
            )
            let transport: GatewayConfiguration.Transport
            if case let .rdGateway(existing) = profile.route {
                transport = existing.transport
            } else {
                transport = .auto
            }
            return (
                .rdGateway(GatewayConfiguration(
                    endpoint: endpoint,
                    credentialReference: credential.reference,
                    transport: transport
                )),
                credential.write.map { [$0] } ?? []
            )
        }
        let credential = try credentialWrite(
            kind: .proxy,
            username: proxyUsernameField.stringValue,
            password: proxyPasswordField.stringValue,
            shouldStore: saveRouteCredentialButton.state == .on,
            existingReference: existingCredentialReference(for: .proxy)
        )
        let proxy = ProxyConfiguration(
            endpoint: endpoint,
            usernameHint: proxyUsernameField.stringValue,
            credentialReference: credential.reference,
            resolvesTargetName: true
        )
        return (
            index == 1 ? .socks5(proxy) : .httpConnect(proxy: proxy, tls: index == 3),
            credential.write.map { [$0] } ?? []
        )
    }

    private func credentialWrite(
        kind: CredentialReference.Kind,
        username: String,
        domain: String = "",
        password: String,
        shouldStore: Bool,
        existingReference: CredentialReference?
    ) throws -> (reference: CredentialReference?, write: CredentialWrite?) {
        guard shouldStore else { return (nil, nil) }

        if password.isEmpty, let existingReference {
            guard let existing = loadedCredentialMaterials[existingReference] else {
                throw ProfileEditorError.savedCredentialUnavailable
            }
            let updated = try CredentialMaterial(
                username: username,
                domain: domain,
                password: existing.password
            ).validated()
            guard updated != existing else { return (existingReference, nil) }
            return newCredentialWrite(kind: kind, material: updated)
        }

        let shouldCreate = kind == .proxy ? (!username.isEmpty || !password.isEmpty) : !password.isEmpty
        guard shouldCreate else { return (nil, nil) }
        return newCredentialWrite(
            kind: kind,
            material: try CredentialMaterial(username: username, domain: domain, password: password).validated()
        )
    }

    private func newCredentialWrite(
        kind: CredentialReference.Kind,
        material: CredentialMaterial
    ) -> (reference: CredentialReference?, write: CredentialWrite?) {
        let reference = CredentialReference(kind: kind)
        return (
            reference,
            CredentialWrite(reference: reference, material: material)
        )
    }

    private func existingCredentialReference(for kind: CredentialReference.Kind) -> CredentialReference? {
        guard enterprisePolicy.allowsCredentialSaving else { return nil }
        switch profile.route {
        case let .socks5(proxy), let .httpConnect(proxy, _):
            return kind == .proxy ? proxy.credentialReference : nil
        case let .rdGateway(gateway):
            return kind == .gateway ? gateway.credentialReference : nil
        case .direct:
            return nil
        }
    }

    private func setSaving(_ saving: Bool) {
        isSaving = saving
        saveButton.isEnabled = !saving
        cancelButton.isEnabled = !saving
        routeTestButton.isEnabled = !saving
    }

    private func validPort(_ control: NSTextField, name: String) throws -> UInt16 {
        try ConnectionFieldParser.port(control.stringValue, field: name)
    }

    private func applyEnterprisePolicy() {
        let managed = NSLocalizedString("Managed by your organization", comment: "managed setting tooltip")
        if !enterprisePolicy.allowsCredentialSaving {
            loadedCredentialMaterials.removeAll()
            passwordField.placeholderString = nil
            proxyPasswordField.placeholderString = nil
            saveTargetCredentialButton.state = .off
            saveTargetCredentialButton.isEnabled = false
            saveTargetCredentialButton.toolTip = managed
            saveRouteCredentialButton.state = .off
            saveRouteCredentialButton.isEnabled = false
            saveRouteCredentialButton.toolTip = managed
        }
        if let scaleMode = enterprisePolicy.forcedScaleMode {
            scalePopup.selectItem(at: scaleMode == .fit ? 0 : scaleMode == .actualSize ? 1 : 2)
            scalePopup.isEnabled = false
            scalePopup.toolTip = managed
        }
        if let maximumAttempts = enterprisePolicy.maximumReconnectAttempts {
            reconnectAttemptsField.integerValue = min(
                reconnectAttemptsField.integerValue,
                Int(maximumAttempts)
            )
            reconnectAttemptsField.toolTip = managed
        }
        if let maximumPreset = enterprisePolicy.maximumRedirectionPreset {
            let maximumIndex = maximumPreset == .secure ? 0 : maximumPreset == .standard ? 1 : 2
            for index in 0..<redirectionPresetPopup.numberOfItems {
                redirectionPresetPopup.item(at: index)?.isEnabled = index <= maximumIndex
            }
            if redirectionPresetPopup.indexOfSelectedItem > maximumIndex {
                redirectionPresetPopup.selectItem(at: maximumIndex)
            }
            redirectionPresetPopup.toolTip = managed
        }

        let permitted = enterprisePolicy.permittedRedirection
        constrain(clipboardTextButton, permitted: permitted.clipboardText, tooltip: managed)
        constrain(clipboardImagesButton, permitted: permitted.clipboardImages, tooltip: managed)
        constrain(clipboardFilesButton, permitted: permitted.clipboardFiles, tooltip: managed)
        constrain(audioButton, permitted: permitted.audioPlayback, tooltip: managed)
        constrain(microphoneButton, permitted: permitted.microphone, tooltip: managed)
        constrain(printersButton, permitted: permitted.printers, tooltip: managed)
        constrain(camerasButton, permitted: permitted.cameras, tooltip: managed)
        constrain(smartCardsButton, permitted: permitted.smartCards, tooltip: managed)
        if enterprisePolicy.maximumRedirectionPreset != nil,
           enterprisePolicy.maximumRedirectionPreset != .complete {
            refreshFolderSummary()
            chooseFoldersButton.isEnabled = false
            clearFoldersButton.isEnabled = false
            chooseFoldersButton.toolTip = managed
            clearFoldersButton.toolTip = managed
        }
    }

    private func constrain(_ button: NSButton, permitted: Bool, tooltip: String) {
        guard !permitted else { return }
        button.state = .off
        button.isEnabled = false
        button.toolTip = tooltip
    }

    @objc private func chooseFolders() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = NSLocalizedString("Share", comment: "share folder")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            do {
                for url in panel.urls {
                    let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    guard !self.sharedFolders.contains(where: { $0.bookmarkData == data }) else { continue }
                    self.sharedFolders.append(SharedFolderBookmark(displayName: url.lastPathComponent, bookmarkData: data))
                }
                self.refreshFolderSummary()
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc private func clearFolders() {
        sharedFolders.removeAll()
        refreshFolderSummary()
    }

    @objc private func redirectionPresetChanged() {
        let defaults = RedirectionPolicy.defaults(for: selectedRedirectionPreset)
        clipboardTextButton.state = defaults.clipboardText ? .on : .off
        clipboardImagesButton.state = defaults.clipboardImages ? .on : .off
        clipboardFilesButton.state = defaults.clipboardFiles ? .on : .off
        audioButton.state = defaults.audioPlayback ? .on : .off
        microphoneButton.state = defaults.microphone ? .on : .off
        printersButton.state = defaults.printers ? .on : .off
        smartCardsButton.state = defaults.smartCards ? .on : .off
    }

    private var selectedRedirectionPreset: RedirectionPolicy.Preset {
        switch redirectionPresetPopup.indexOfSelectedItem {
        case 0: return .secure
        case 2: return .complete
        default: return .standard
        }
    }

    @objc private func testConnectionPath() {
        if routeTestTask != nil {
            routeTestGeneration &+= 1
            routeTestTask?.cancel()
            routeTestTask = nil
            routeTestButton.title = NSLocalizedString("Test Connection", comment: "test route")
            return
        }
        do {
            let target = TargetIdentity(
                endpoint: Endpoint(host: hostField.stringValue, port: try validPort(portField, name: "target")),
                certificateName: certificateNameField.stringValue.isEmpty ? hostField.stringValue : certificateNameField.stringValue
            )
            let route = try routeForTest()
            let credential: ProxyCredential?
            switch route {
            case .socks5, .httpConnect:
                credential = try proxyCredentialForTest()
            default: credential = nil
            }
            routeTestButton.title = NSLocalizedString("Cancel Test", comment: "cancel route test")
            routeTestGeneration &+= 1
            let generation = routeTestGeneration
            routeTestTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.routeTestGeneration == generation {
                        self.routeTestTask = nil
                        self.routeTestButton.title = NSLocalizedString("Test Connection", comment: "test route")
                    }
                }
                do {
                    let report = try await RouteProbe().test(target: target, route: route, credential: credential)
                    guard self.routeTestGeneration == generation else { return }
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Connection path succeeded", comment: "route success")
                    alert.informativeText = String(format: NSLocalizedString("Stage: %@\nElapsed: %d ms\nCertificate identity: %@", comment: "route result"), report.stage.rawValue, report.durationMilliseconds, report.certificateName)
                    if let window = self.window { _ = await alert.beginSheetModal(for: window) }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.routeTestGeneration == generation else { return }
                    if let window = self.window { _ = await NSAlert(error: error).beginSheetModal(for: window) }
                }
            }
        } catch {
            guard let window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    private func routeForTest() throws -> RouteConfiguration {
        let index = routePopup.indexOfSelectedItem
        guard index != 0 else { return .direct }
        let endpoint = Endpoint(
            host: proxyHostField.stringValue,
            port: try validPort(proxyPortField, name: index == 4 ? "gateway" : "proxy")
        )
        if index == 4 { return .rdGateway(GatewayConfiguration(endpoint: endpoint)) }
        let proxy = ProxyConfiguration(endpoint: endpoint, resolvesTargetName: true)
        return index == 1 ? .socks5(proxy) : .httpConnect(proxy: proxy, tls: index == 3)
    }

    private func proxyCredentialForTest() throws -> ProxyCredential? {
        if !proxyPasswordField.stringValue.isEmpty {
            return ProxyCredential(username: proxyUsernameField.stringValue, password: proxyPasswordField.stringValue)
        }
        if let reference = existingCredentialReference(for: .proxy),
           let material = loadedCredentialMaterials[reference] {
            let username = proxyUsernameField.stringValue.isEmpty ? material.username : proxyUsernameField.stringValue
            return ProxyCredential(username: username, password: material.password)
        }
        guard proxyUsernameField.stringValue.isEmpty else {
            throw ProfileEditorError.incompleteProxyCredential
        }
        return nil
    }

    private func refreshFolderSummary() {
        folderSummary.stringValue = sharedFolders.isEmpty
            ? NSLocalizedString("No folders shared", comment: "no shared folders")
            : sharedFolders.map(\.displayName).joined(separator: ", ")
    }
}

enum ConnectionFieldParser {
    static func port(_ rawValue: String, field: String) throws -> UInt16 {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsed = UInt32(value),
              (1...65_535).contains(parsed) else {
            throw ProfileValidationError.invalidPort(field)
        }
        return UInt16(parsed)
    }
}

private enum ProfileEditorError: Error, LocalizedError {
    case savedCredentialUnavailable
    case incompleteProxyCredential

    var errorDescription: String? {
        switch self {
        case .savedCredentialUnavailable:
            return NSLocalizedString(
                "The saved Keychain credential is unavailable. Enter the password again or turn off Keychain saving.",
                comment: "saved credential unavailable"
            )
        case .incompleteProxyCredential:
            return NSLocalizedString(
                "A proxy username and password are required for proxy authentication.",
                comment: "incomplete proxy credential"
            )
        }
    }
}
