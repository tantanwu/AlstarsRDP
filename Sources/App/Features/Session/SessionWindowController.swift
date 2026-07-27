import AppKit
import Diagnostics
import Network
import Persistence
import RDPBridge
import RDPDomain
import RDPRenderer
import RDPTransport

@MainActor
final class SessionWindowController: NSWindowController, NSWindowDelegate, RDPSessionDelegate {
    private let sessionID: UUID
    private var profile: ConnectionProfile
    private let credentialStore: CredentialStoring
    private let diagnostics: DiagnosticTimeline
    private let onProfileUpdate: (ProfileSaveRequest) async throws -> Void
    private let onClose: (UUID) -> Void
    private let automaticReconnectEnabled: Bool
    private let enterprisePolicy: EnterprisePolicy
    private let canvas: RemoteFrameView
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var session: RDPSession?
    private var tunnel: LoopbackTunnel?
    private var connectTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var ephemeralCredential: CredentialMaterial?
    private var ephemeralProxyCredential: CredentialMaterial?
    private var ephemeralGatewayCredential: CredentialMaterial?
    private var reconnectAttempt: UInt8 = 0
    private var reconnectWhenStopped = false
    private var permitsAutomaticReconnect: Bool
    private var isClosing = false
    private var connectionGeneration: UInt64 = 0
    private let networkPathMonitor = NWPathMonitor()
    private let networkPathQueue = DispatchQueue(label: "com.example.RemoteDesktop.session-network")
    private var networkWasAvailable = true
    private var reconnectAfterNetworkRestored = false
    private var isSleeping = false
    private var pressedScanCodes = Set<UInt32>()
    private var modifierState: NSEvent.ModifierFlags = []

    init(
        sessionID: UUID,
        profile: ConnectionProfile,
        credentialStore: CredentialStoring,
        diagnostics: DiagnosticTimeline,
        automaticReconnectEnabled: Bool,
        enterprisePolicy: EnterprisePolicy = .unrestricted,
        onProfileUpdate: @escaping (ProfileSaveRequest) async throws -> Void,
        onClose: @escaping (UUID) -> Void
    ) {
        self.sessionID = sessionID
        self.profile = profile
        self.credentialStore = credentialStore
        self.diagnostics = diagnostics
        self.automaticReconnectEnabled = automaticReconnectEnabled
        self.enterprisePolicy = enterprisePolicy
        self.permitsAutomaticReconnect = automaticReconnectEnabled
        self.onProfileUpdate = onProfileUpdate
        self.onClose = onClose
        self.canvas = RemoteFrameView(scaleMode: profile.display.scaleMode)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullScreen],
            backing: .buffered, defer: false
        )
        window.title = profile.name
        window.minSize = NSSize(width: 640, height: 400)
        window.acceptsMouseMovedEvents = true
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
        bindInput()
        observeSystemState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        networkPathMonitor.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func connect() {
        reconnectAttempt = 0
        permitsAutomaticReconnect = automaticReconnectEnabled
        startConnection()
    }

    private func startConnection() {
        guard !isClosing, connectTask == nil, session == nil else { return }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        showStatus(NSLocalizedString("Preparing connection…", comment: "preparing"), busy: true)
        connectTask = Task { [weak self] in
            guard let self else { return }
            var preparedTunnel: LoopbackTunnel?
            do {
                guard let targetCredential = try await self.resolveTargetCredential() else {
                    guard self.connectionGeneration == generation else { return }
                    self.connectTask = nil
                    self.clearEphemeralCredentials()
                    self.showStatus(NSLocalizedString("Connection cancelled", comment: "credential cancelled"), busy: false)
                    return
                }
                try Task.checkCancellation()
                guard self.profile.redirection.sharedFolders.isEmpty else {
                    throw SessionPreparationError.folderMappingUnavailable
                }

                let gatewayCredential: CredentialMaterial?
                if case .rdGateway = self.profile.route {
                    guard let credential = try await self.resolveGatewayCredential() else {
                        guard self.connectionGeneration == generation else { return }
                        self.connectTask = nil
                        self.releaseConnectionResources()
                        self.clearEphemeralCredentials()
                        self.showStatus(NSLocalizedString("Connection cancelled", comment: "credential cancelled"), busy: false)
                        return
                    }
                    gatewayCredential = credential
                } else {
                    gatewayCredential = nil
                }
                let proxyCredential = try await self.resolveProxyCredential()

                let configuration = RDPConnectionConfiguration()
                configuration.certificateName = self.profile.target.certificateName
                configuration.username = targetCredential.username
                configuration.domain = targetCredential.domain
                configuration.password = targetCredential.password
                configuration.desktopWidth = self.profile.display.width
                configuration.desktopHeight = self.profile.display.height
                configuration.dynamicResolution = self.profile.display.scaleMode == .dynamicResolution
                configuration.redirectClipboard = self.profile.redirection.clipboardText || self.profile.redirection.clipboardImages || self.profile.redirection.clipboardFiles
                configuration.audioPlayback = self.profile.redirection.audioPlayback
                configuration.audioCapture = self.profile.redirection.microphone
                configuration.redirectDrives = false
                configuration.redirectDrivePaths = []
                configuration.redirectPrinters = self.profile.redirection.printers
                configuration.redirectSmartCards = self.profile.redirection.smartCards

                switch self.profile.route {
                case .direct:
                    configuration.connectionHost = self.profile.target.endpoint.host
                    configuration.connectionPort = self.profile.target.endpoint.port
                case .socks5, .httpConnect:
                    let routeConnector = RouteConnector(diagnostics: self.diagnostics)
                    let tunnel = LoopbackTunnel(routeConnector: routeConnector)
                    preparedTunnel = tunnel
                    let local = try await tunnel.start(
                        target: self.profile.target,
                        route: self.profile.route,
                        credential: proxyCredential.map { ProxyCredential(username: $0.username, password: $0.password) }
                    )
                    try Task.checkCancellation()
                    guard self.connectionGeneration == generation, !self.isClosing else {
                        tunnel.stop()
                        return
                    }
                    self.tunnel = tunnel
                    configuration.connectionHost = local.host
                    configuration.connectionPort = local.port
                case let .rdGateway(gateway):
                    configuration.connectionHost = self.profile.target.endpoint.host
                    configuration.connectionPort = self.profile.target.endpoint.port
                    configuration.gatewayHost = gateway.endpoint.host
                    configuration.gatewayPort = gateway.endpoint.port
                    configuration.gatewayUsername = gatewayCredential?.username ?? ""
                    configuration.gatewayDomain = gatewayCredential?.domain ?? ""
                    configuration.gatewayPassword = gatewayCredential?.password ?? ""
                    configuration.gatewayHTTPTransport = gateway.transport != .rpc
                    configuration.gatewayRPCTransport = gateway.transport != .http
                }

                try Task.checkCancellation()
                guard self.connectionGeneration == generation, !self.isClosing else {
                    preparedTunnel?.stop()
                    return
                }
                let session = RDPSession(configuration: configuration)
                session.delegate = self
                self.session = session
                self.connectTask = nil
                self.showStatus(NSLocalizedString("Connecting…", comment: "connecting"), busy: true)
                session.start()
            } catch SessionPreparationError.cancelled {
                preparedTunnel?.stop()
                guard self.connectionGeneration == generation else { return }
                self.connectTask = nil
                self.releaseConnectionResources()
                self.clearEphemeralCredentials()
                self.showStatus(NSLocalizedString("Connection cancelled", comment: "credential cancelled"), busy: false)
            } catch {
                preparedTunnel?.stop()
                guard self.connectionGeneration == generation else { return }
                self.connectTask = nil
                self.releaseConnectionResources()
                self.clearEphemeralCredentials()
                self.showStatus(error.localizedDescription, busy: false)
                await self.diagnostics.record(DiagnosticEvent(
                    level: .error, category: .transport, code: "CONNECT_PREPARE_FAILED",
                    message: "Connection preparation failed.",
                    fields: [
                        "targetHost": .privateText(self.profile.target.endpoint.host),
                        "errorDetail": .privateText(error.localizedDescription)
                    ]
                ))
            }
        }
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal; toolbar.alignment = .centerY; toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addArrangedSubview(button(symbol: "rectangle.portrait.and.arrow.right", tooltip: NSLocalizedString("Disconnect", comment: "disconnect"), action: #selector(disconnect)))
        toolbar.addArrangedSubview(button(symbol: "arrow.clockwise", tooltip: NSLocalizedString("Reconnect", comment: "reconnect"), action: #selector(reconnect)))
        toolbar.addArrangedSubview(button(symbol: "rectangle.inset.filled", tooltip: NSLocalizedString("Toggle Full Screen", comment: "full screen"), action: #selector(toggleFullScreen)))
        toolbar.addArrangedSubview(button(symbol: "keyboard", tooltip: NSLocalizedString("Send Control-Alt-Delete", comment: "cad"), action: #selector(sendControlAltDelete)))
        toolbar.addArrangedSubview(NSView())
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingTail
        toolbar.addArrangedSubview(progress); toolbar.addArrangedSubview(statusLabel)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar); content.addSubview(canvas)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func button(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .texturedRounded; button.toolTip = tooltip; button.setAccessibilityLabel(tooltip)
        return button
    }

    private func bindInput() {
        canvas.capturesCommandKeyEquivalents = profile.display.keyboardMode == .windowsPreferred
        canvas.onMouse = { [weak self] event, point, down, button, move in
            guard let self else { return }
            let remoteButton: RDPMouseButton = button == 1 ? .left : button == 2 ? .right : button == 3 ? .middle : []
            self.session?.sendMouse(atX: UInt16(clamping: Int(point.x)), y: UInt16(clamping: Int(point.y)), buttons: remoteButton, keyDown: down, move: move)
        }
        canvas.onScroll = { [weak self] event, point in
            guard let self else { return }
            let x = UInt16(clamping: Int(point.x)), y = UInt16(clamping: Int(point.y))
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                self.session?.sendHorizontalScroll(Int16(clamping: Int(event.scrollingDeltaX * 8)), atX: x, y: y)
            } else {
                self.session?.sendVerticalScroll(Int16(clamping: Int(event.scrollingDeltaY * 8)), atX: x, y: y)
            }
        }
        canvas.onKey = { [weak self] event, down in self?.send(event: event, down: down) }
        canvas.onFlagsChanged = { [weak self] event in self?.sendModifiers(event.modifierFlags) }
        canvas.onFocusLost = { [weak self] in self?.releaseAllKeys() }
    }

    private func send(event: NSEvent, down: Bool) {
        if let scan = MacKeyMapper.scanCode(for: event) {
            session?.sendScanCode(scan, keyDown: down)
            if down { pressedScanCodes.insert(scan) } else { pressedScanCodes.remove(scan) }
        } else if let codeUnits = event.charactersIgnoringModifiers?.utf16 {
            for codeUnit in codeUnits {
                session?.sendUnicodeScalar(codeUnit, keyDown: down)
            }
        }
    }

    private func sendModifiers(_ flags: NSEvent.ModifierFlags) {
        var monitored: [(NSEvent.ModifierFlags, UInt32)] = [(.shift, 0x2a), (.control, 0x1d), (.option, 0x38)]
        if profile.display.keyboardMode == .windowsPreferred {
            monitored.append((.command, 0x0100 | 0x5b))
        }
        for (flag, scan) in monitored {
            let wasDown = modifierState.contains(flag), isDown = flags.contains(flag)
            if wasDown != isDown { session?.sendScanCode(scan, keyDown: isDown); if isDown { pressedScanCodes.insert(scan) } else { pressedScanCodes.remove(scan) } }
        }
        modifierState = flags.intersection([.shift, .control, .option, .command])
    }

    private func releaseAllKeys() {
        for scan in pressedScanCodes { session?.sendScanCode(scan, keyDown: false) }
        pressedScanCodes.removeAll(); modifierState = []
    }

    @objc private func disconnect() {
        connectionGeneration &+= 1
        permitsAutomaticReconnect = false
        reconnectWhenStopped = false
        retryTask?.cancel(); retryTask = nil
        connectTask?.cancel(); connectTask = nil
        clearEphemeralCredentials()
        releaseAllKeys()
        if let session {
            session.disconnect()
        } else {
            releaseConnectionResources()
            showStatus(NSLocalizedString("Disconnected", comment: "disconnected"), busy: false)
        }
    }

    @objc private func reconnect() {
        connectionGeneration &+= 1
        permitsAutomaticReconnect = false
        reconnectAttempt = 0
        retryTask?.cancel(); retryTask = nil
        connectTask?.cancel(); connectTask = nil
        reconnectWhenStopped = true
        releaseAllKeys()
        if let session {
            showStatus(NSLocalizedString("Restarting connection…", comment: "manual reconnect"), busy: true)
            session.disconnect()
        } else {
            reconnectWhenStopped = false
            releaseConnectionResources()
            permitsAutomaticReconnect = automaticReconnectEnabled
            startConnection()
        }
    }
    @objc private func toggleFullScreen() { window?.toggleFullScreen(nil) }
    @objc private func sendControlAltDelete() { session?.sendControlAltDelete() }

    func session(_ session: RDPSession, didChange state: RDPNativeSessionState, errorCode: UInt32) {
        guard self.session === session else { return }
        Task {
            await diagnostics.record(DiagnosticEvent(
                level: state == .failed ? .error : .info,
                category: .rdp,
                code: "RDP_STATE_\(state.rawValue)",
                message: Self.stateDescription(state),
                fields: [
                    "sessionID": .privateText(sessionID.uuidString),
                    "errorCode": .number(Double(errorCode))
                ]
            ))
        }
        switch state {
        case .idle: showStatus(NSLocalizedString("Idle", comment: "idle"), busy: false)
        case .connecting: showStatus(NSLocalizedString("Negotiating TLS and authentication…", comment: "negotiating"), busy: true)
        case .connected:
            reconnectAttempt = 0
            showStatus(NSLocalizedString("Connected", comment: "connected"), busy: false)
            window?.makeFirstResponder(canvas)
        case .disconnecting: showStatus(NSLocalizedString("Disconnecting…", comment: "disconnecting"), busy: true)
        case .closed:
            finish(session: session)
            if reconnectWhenStopped {
                reconnectWhenStopped = false
                permitsAutomaticReconnect = automaticReconnectEnabled
                startConnection()
            } else if reconnectAfterNetworkRestored && networkWasAvailable {
                restartAfterNetworkRestored()
            } else {
                showStatus(NSLocalizedString("Disconnected", comment: "disconnected"), busy: false)
            }
        case .failed:
            finish(session: session)
            handleFailure(errorCode)
        @unknown default: showStatus(NSLocalizedString("Unknown session state", comment: "unknown"), busy: false)
        }
    }

    func session(_ session: RDPSession, didReceiveFrame frame: Data, width: UInt32, height: UInt32, stride: UInt32) {
        guard self.session === session else { return }
        canvas.updateFrame(frame, width: Int(width), height: Int(height), stride: Int(stride))
    }

    func session(_ session: RDPSession, decideCertificate certificate: RDPCertificateInfo) -> RDPCertificateDecision {
        guard self.session === session, !isClosing else { return .reject }
        let alert = NSAlert()
        alert.alertStyle = certificate.changed ? .critical : .warning
        alert.messageText = certificate.changed ? NSLocalizedString("The remote certificate changed", comment: "changed certificate") : NSLocalizedString("Trust this remote certificate?", comment: "unknown certificate")
        let fingerprint = certificate.fingerprintOrPEM.hasPrefix("-----BEGIN") ? NSLocalizedString("A PEM certificate was supplied. Review the subject and issuer before trusting.", comment: "pem detail") : certificate.fingerprintOrPEM
        alert.informativeText = "\(certificate.host):\(certificate.port)\n\(certificate.subject)\n\(certificate.issuer)\n\(fingerprint)"
        alert.addButton(withTitle: NSLocalizedString("Trust and Save", comment: "trust save"))
        alert.addButton(withTitle: NSLocalizedString("Trust Once", comment: "trust once"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .trustAndStore
        case .alertSecondButtonReturn: return .trustForSession
        default: return .reject
        }
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        clearEphemeralCredentials()
        retryTask?.cancel(); retryTask = nil
        connectTask?.cancel(); connectTask = nil
        disconnect()
        onClose(sessionID)
    }

    private func finish(session finishedSession: RDPSession) {
        guard session === finishedSession else { return }
        finishedSession.delegate = nil
        session = nil
        connectTask = nil
        releaseConnectionResources()
    }

    private func releaseConnectionResources() {
        tunnel?.stop()
        tunnel = nil
    }

    private func clearEphemeralCredentials() {
        ephemeralCredential = nil
        ephemeralProxyCredential = nil
        ephemeralGatewayCredential = nil
    }

    private func handleFailure(_ errorCode: UInt32) {
        let disposition = RDPFailureClassifier.disposition(for: errorCode)
        guard permitsAutomaticReconnect, !isClosing, disposition == .retryable,
              reconnectAttempt < profile.reconnect.maximumAttempts else {
            clearEphemeralCredentials()
            showStatus(String(format: NSLocalizedString("Connection failed (0x%08X)", comment: "failure code"), errorCode), busy: false)
            return
        }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = ReconnectBackoff.delayMilliseconds(forAttempt: attempt, policy: profile.reconnect)
        showStatus(
            String(format: NSLocalizedString("Connection lost. Retry %d of %d in %.1f seconds…", comment: "automatic reconnect"), attempt, profile.reconnect.maximumAttempts, Double(delay) / 1_000),
            busy: true
        )
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
            catch { return }
            guard let self, !self.isClosing, self.permitsAutomaticReconnect else { return }
            self.retryTask = nil
            self.startConnection()
        }
    }

    private func observeSystemState() {
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        notifications.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            DispatchQueue.main.async { [weak self] in
                self?.networkPathDidChange(isAvailable: isAvailable)
            }
        }
        networkPathMonitor.start(queue: networkPathQueue)
    }

    @objc private func systemWillSleep() {
        isSleeping = true
        reconnectAfterNetworkRestored = false
        retryTask?.cancel(); retryTask = nil
        connectionGeneration &+= 1
        connectTask?.cancel(); connectTask = nil
        clearEphemeralCredentials()
        permitsAutomaticReconnect = false
        releaseAllKeys()
        releaseConnectionResources()
        session?.disconnect()
        showStatus(NSLocalizedString("Disconnected because this Mac is sleeping", comment: "sleep disconnect"), busy: false)
    }

    @objc private func systemDidWake() {
        isSleeping = false
        showStatus(NSLocalizedString("This Mac woke from sleep. Reconnect manually when ready.", comment: "wake reconnect manually"), busy: false)
    }

    private func networkPathDidChange(isAvailable: Bool) {
        guard !isClosing else { return }
        guard isAvailable != networkWasAvailable else { return }
        networkWasAvailable = isAvailable
        if !isAvailable {
            guard !isSleeping else { return }
            let hadActiveConnection = session != nil || connectTask != nil
            reconnectAfterNetworkRestored = automaticReconnectEnabled && hadActiveConnection
            retryTask?.cancel(); retryTask = nil
            connectionGeneration &+= 1
            connectTask?.cancel(); connectTask = nil
            permitsAutomaticReconnect = false
            releaseAllKeys()
            releaseConnectionResources()
            session?.disconnect()
            showStatus(NSLocalizedString("Network unavailable. Waiting for a usable network path…", comment: "network unavailable"), busy: true)
        } else if reconnectAfterNetworkRestored, session == nil {
            restartAfterNetworkRestored()
        }
    }

    private func restartAfterNetworkRestored() {
        guard reconnectAfterNetworkRestored, networkWasAvailable, !isSleeping else { return }
        reconnectAfterNetworkRestored = false
        permitsAutomaticReconnect = automaticReconnectEnabled
        reconnectAttempt = 0
        showStatus(NSLocalizedString("Network restored. Reconnecting…", comment: "network restored"), busy: true)
        startConnection()
    }

    private func resolveTargetCredential() async throws -> CredentialMaterial? {
        if let ephemeralCredential { return ephemeralCredential }
        if let reference = profile.credentialReference,
           let stored = try credentialStore.load(reference: reference),
           !stored.username.isEmpty, !stored.password.isEmpty {
            return stored
        }

        let username = NSTextField(string: profile.usernameHint)
        let domain = NSTextField(string: profile.domainHint)
        let password = NSSecureTextField()
        let save = NSButton(checkboxWithTitle: NSLocalizedString("Save in Keychain", comment: "save credential"), target: nil, action: nil)
        configureCredentialSaving(save)
        let accessory = credentialAccessory(username: username, domain: domain, password: password, save: save)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Windows credentials required", comment: "credential prompt title")
        alert.informativeText = String(format: NSLocalizedString("Enter credentials for %@. They are used only for this connection unless you choose to save them.", comment: "credential prompt detail"), profile.target.endpoint.host)
        alert.accessoryView = accessory
        alert.addButton(withTitle: NSLocalizedString("Connect", comment: "connect"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard !username.stringValue.isEmpty, !password.stringValue.isEmpty else {
            throw SessionPreparationError.incompleteCredential
        }
        let material = try CredentialMaterial(username: username.stringValue, domain: domain.stringValue, password: password.stringValue).validated()
        profile.usernameHint = material.username
        profile.domainHint = material.domain
        if save.state == .on {
            let baseProfile = profile
            let oldReference = profile.credentialReference
            let newReference = CredentialReference(kind: .target)
            var updated = profile
            updated.credentialReference = newReference
            updated.updatedAt = Date()
            try await onProfileUpdate(ProfileSaveRequest(
                profile: updated,
                credentialWrites: [CredentialWrite(reference: newReference, material: material)],
                obsoleteCredentialReferences: Set([oldReference].compactMap { $0 }),
                scope: .credentialsOnly,
                baseProfile: baseProfile
            ))
            profile = updated
        } else {
            ephemeralCredential = material
        }
        return material
    }

    private func resolveGatewayCredential() async throws -> CredentialMaterial? {
        guard case let .rdGateway(gateway) = profile.route else { return nil }
        if let ephemeralGatewayCredential { return ephemeralGatewayCredential }
        if let reference = gateway.credentialReference,
           let stored = try credentialStore.load(reference: reference),
           !stored.username.isEmpty, !stored.password.isEmpty {
            return stored
        }
        let username = NSTextField()
        let domain = NSTextField()
        let password = NSSecureTextField()
        let save = NSButton(checkboxWithTitle: NSLocalizedString("Save in Keychain", comment: "save credential"), target: nil, action: nil)
        configureCredentialSaving(save)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("RD Gateway credentials required", comment: "gateway credential prompt title")
        alert.informativeText = String(format: NSLocalizedString("Enter credentials for the RD Gateway %@. These are separate from the Windows host credentials.", comment: "gateway credential prompt detail"), gateway.endpoint.host)
        alert.accessoryView = credentialAccessory(username: username, domain: domain, password: password, save: save)
        alert.addButton(withTitle: NSLocalizedString("Connect", comment: "connect"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard !username.stringValue.isEmpty, !password.stringValue.isEmpty else {
            throw SessionPreparationError.incompleteCredential
        }
        let material = try CredentialMaterial(username: username.stringValue, domain: domain.stringValue, password: password.stringValue).validated()
        if save.state == .on {
            let baseProfile = profile
            var updatedGateway = gateway
            let oldReference = updatedGateway.credentialReference
            let newReference = CredentialReference(kind: .gateway)
            updatedGateway.credentialReference = newReference
            var updated = profile
            updated.route = .rdGateway(updatedGateway)
            updated.updatedAt = Date()
            try await onProfileUpdate(ProfileSaveRequest(
                profile: updated,
                credentialWrites: [CredentialWrite(reference: newReference, material: material)],
                obsoleteCredentialReferences: Set([oldReference].compactMap { $0 }),
                scope: .credentialsOnly,
                baseProfile: baseProfile
            ))
            profile = updated
        } else {
            ephemeralGatewayCredential = material
        }
        return material
    }

    private func resolveProxyCredential() async throws -> CredentialMaterial? {
        let proxy: RDPDomain.ProxyConfiguration
        switch profile.route {
        case let .socks5(configuration), let .httpConnect(configuration, _):
            proxy = configuration
        default:
            return nil
        }
        if let ephemeralProxyCredential { return ephemeralProxyCredential }
        if let reference = proxy.credentialReference,
           let stored = try credentialStore.load(reference: reference),
           !stored.username.isEmpty, !stored.password.isEmpty {
            return stored
        }
        guard proxy.expectsCredentials else { return nil }

        let username = NSTextField(string: proxy.usernameHint)
        let password = NSSecureTextField()
        let save = NSButton(checkboxWithTitle: NSLocalizedString("Save in Keychain", comment: "save credential"), target: nil, action: nil)
        configureCredentialSaving(save)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: NSLocalizedString("Username", comment: "username")), username],
            [NSTextField(labelWithString: NSLocalizedString("Password", comment: "password")), password],
            [NSView(), save]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 250
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 350, height: 85)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Proxy credentials required", comment: "proxy credential prompt title")
        alert.informativeText = String(
            format: NSLocalizedString("Enter credentials for the proxy %@.", comment: "proxy credential prompt detail"),
            proxy.endpoint.host
        )
        alert.accessoryView = grid
        alert.addButton(withTitle: NSLocalizedString("Connect", comment: "connect"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { throw SessionPreparationError.cancelled }
        guard !username.stringValue.isEmpty, !password.stringValue.isEmpty else {
            throw SessionPreparationError.incompleteProxyCredential
        }
        let material = try CredentialMaterial(username: username.stringValue, password: password.stringValue).validated()
        if save.state == .on {
            let baseProfile = profile
            let oldReference = proxy.credentialReference
            let newReference = CredentialReference(kind: .proxy)
            var updatedProxy = proxy
            updatedProxy.usernameHint = material.username
            updatedProxy.credentialReference = newReference
            var updated = profile
            switch profile.route {
            case .socks5:
                updated.route = .socks5(updatedProxy)
            case let .httpConnect(_, tls):
                updated.route = .httpConnect(proxy: updatedProxy, tls: tls)
            default:
                return nil
            }
            updated.updatedAt = Date()
            try await onProfileUpdate(ProfileSaveRequest(
                profile: updated,
                credentialWrites: [CredentialWrite(reference: newReference, material: material)],
                obsoleteCredentialReferences: Set([oldReference].compactMap { $0 }),
                scope: .credentialsOnly,
                baseProfile: baseProfile
            ))
            profile = updated
        } else {
            ephemeralProxyCredential = material
        }
        return material
    }

    private func credentialAccessory(
        username: NSTextField, domain: NSTextField, password: NSSecureTextField, save: NSButton
    ) -> NSView {
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: NSLocalizedString("Username", comment: "username")), username],
            [NSTextField(labelWithString: NSLocalizedString("Domain", comment: "domain")), domain],
            [NSTextField(labelWithString: NSLocalizedString("Password", comment: "password")), password],
            [NSView(), save]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 250
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 350, height: 110)
        return grid
    }

    private func configureCredentialSaving(_ button: NSButton) {
        guard !enterprisePolicy.allowsCredentialSaving else { return }
        button.state = .off
        button.isEnabled = false
        button.toolTip = NSLocalizedString("Managed by your organization", comment: "managed setting tooltip")
    }

    private func showStatus(_ text: String, busy: Bool) {
        statusLabel.stringValue = text
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private static func stateDescription(_ state: RDPNativeSessionState) -> String {
        switch state {
        case .idle: return "The RDP session is idle."
        case .connecting: return "The RDP session is connecting."
        case .connected: return "The RDP session is connected."
        case .disconnecting: return "The RDP session is disconnecting."
        case .closed: return "The RDP session is closed."
        case .failed: return "The RDP session failed."
        @unknown default: return "The RDP session entered an unknown state."
        }
    }
}

private enum SessionPreparationError: Error, LocalizedError {
    case cancelled
    case incompleteCredential
    case incompleteProxyCredential
    case folderMappingUnavailable

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return NSLocalizedString("Connection cancelled", comment: "credential cancelled")
        case .incompleteCredential:
            return NSLocalizedString("A username and password are required for NLA authentication.", comment: "incomplete credential")
        case .incompleteProxyCredential:
            return NSLocalizedString("A proxy username and password are required for proxy authentication.", comment: "incomplete proxy credential")
        case .folderMappingUnavailable:
            return NSLocalizedString("Folder redirection is not available until the bundled FreeRDP channel build has passed validation.", comment: "folder mapping unavailable")
        }
    }
}
