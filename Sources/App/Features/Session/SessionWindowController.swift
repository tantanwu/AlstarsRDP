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
    private let toolbarContainer = SessionToolbarContainer()
    private let toolbar = NSStackView()
    private let toolbarNotch = NSView()
    private let remoteSizeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let statusOverlay = NSStackView()
    private let retryButton = NSButton(
        title: NSLocalizedString("Try Again", comment: "retry connection"),
        target: nil,
        action: nil
    )
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
    private var adaptiveResizeTask: Task<Void, Never>?
    private var adaptiveResizeGeneration: UInt64 = 0
    private var lastAdaptiveMetrics: AdaptiveDesktopMetrics?
    private var requestedAdaptiveMetrics: AdaptiveDesktopMetrics?
    private var adaptiveConfirmationTask: Task<Void, Never>?
    private var adaptiveRetryCount = 0
    private var displayControlActivated = false
    private var lastRemoteFrameWidth: UInt32 = 0
    private var lastRemoteFrameHeight: UInt32 = 0
    private var lastResizeRejectionMetrics: AdaptiveDesktopMetrics?
    private var fullscreenToolbarCollapseTask: Task<Void, Never>?
    private var isSessionFullScreen = false
    private var toolbarTopConstraint: NSLayoutConstraint?
    private var toolbarLeadingConstraint: NSLayoutConstraint?
    private var toolbarTrailingConstraint: NSLayoutConstraint?
    private var toolbarWidthConstraint: NSLayoutConstraint?
    private var toolbarHeightConstraint: NSLayoutConstraint?
    private var toolbarContentConstraints: [NSLayoutConstraint] = []
    private var canvasTopToToolbarConstraint: NSLayoutConstraint?
    private var canvasTopToContentConstraint: NSLayoutConstraint?

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = profile.name
        window.minSize = NSSize(width: 640, height: 400)
        window.collectionBehavior.insert(.fullScreenPrimary)
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
                configuration.username = targetCredential.username
                configuration.domain = targetCredential.domain
                configuration.password = targetCredential.password
                configuration.dynamicResolution = self.profile.display.scaleMode == .dynamicResolution
                if configuration.dynamicResolution,
                   let metrics = self.currentAdaptiveMetrics() {
                    configuration.desktopWidth = metrics.width
                    configuration.desktopHeight = metrics.height
                    configuration.desktopScaleFactor = metrics.desktopScaleFactor
                    configuration.deviceScaleFactor = metrics.deviceScaleFactor
                } else {
                    configuration.desktopWidth = self.profile.display.width
                    configuration.desktopHeight = self.profile.display.height
                }
                configuration.redirectClipboard = self.profile.redirection.clipboardText || self.profile.redirection.clipboardImages || self.profile.redirection.clipboardFiles
                configuration.audioPlayback = self.profile.redirection.audioPlayback
                configuration.audioCapture = self.profile.redirection.microphone
                configuration.redirectDrives = false
                configuration.redirectDrivePaths = []
                configuration.redirectPrinters = self.profile.redirection.printers
                configuration.redirectSmartCards = self.profile.redirection.smartCards

                switch self.profile.route {
                case .direct:
                    configuration.configureServerAddress(
                        target: self.profile.target,
                        connectionEndpoint: self.profile.target.endpoint
                    )
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
                    configuration.configureServerAddress(
                        target: self.profile.target,
                        connectionEndpoint: Endpoint(host: local.host, port: local.port)
                    )
                case let .rdGateway(gateway):
                    configuration.configureServerAddress(
                        target: self.profile.target,
                        connectionEndpoint: self.profile.target.endpoint
                    )
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
                self.showStatus(error.localizedDescription, busy: false, retryable: true)
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
        toolbar.orientation = .horizontal; toolbar.alignment = .centerY; toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addArrangedSubview(button(
            symbols: ["xmark.circle", "stop.circle"],
            fallbackName: NSImage.stopProgressTemplateName,
            tooltip: NSLocalizedString("Disconnect", comment: "disconnect"),
            action: #selector(disconnect)
        ))
        toolbar.addArrangedSubview(button(
            symbols: ["arrow.clockwise"],
            fallbackName: NSImage.refreshTemplateName,
            tooltip: NSLocalizedString("Reconnect", comment: "reconnect"),
            action: #selector(reconnect)
        ))
        toolbar.addArrangedSubview(button(
            symbols: ["arrow.up.left.and.arrow.down.right"],
            fallbackName: NSImage.enterFullScreenTemplateName,
            tooltip: NSLocalizedString("Toggle Full Screen", comment: "full screen"),
            action: #selector(toggleFullScreen)
        ))
        toolbar.addArrangedSubview(button(
            symbols: ["keyboard"],
            fallbackName: NSImage.actionTemplateName,
            tooltip: NSLocalizedString("Send Control-Alt-Delete", comment: "cad"),
            action: #selector(sendControlAltDelete)
        ))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)
        remoteSizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        remoteSizeLabel.textColor = .secondaryLabelColor
        remoteSizeLabel.alignment = .right
        remoteSizeLabel.lineBreakMode = .byClipping
        remoteSizeLabel.toolTip = NSLocalizedString("Remote frame size", comment: "remote frame size")
        remoteSizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        remoteSizeLabel.isHidden = true
        toolbar.addArrangedSubview(remoteSizeLabel)

        toolbarContainer.identifier = NSUserInterfaceItemIdentifier("SessionToolbarContainer")
        toolbarContainer.translatesAutoresizingMaskIntoConstraints = false
        toolbarContainer.wantsLayer = true
        toolbarContainer.layer?.masksToBounds = true
        toolbarContainer.onHoverChanged = { [weak self] hovering in
            guard let self, self.isSessionFullScreen else { return }
            if hovering {
                self.showFullscreenToolbar()
            } else {
                self.scheduleFullscreenToolbarCollapse()
            }
        }
        toolbarNotch.translatesAutoresizingMaskIntoConstraints = false
        toolbarNotch.wantsLayer = true
        toolbarNotch.layer?.backgroundColor = NSColor(calibratedWhite: 0.72, alpha: 0.9).cgColor
        toolbarNotch.layer?.cornerRadius = 2
        toolbarNotch.isHidden = true
        toolbarContainer.addSubview(toolbar)
        toolbarContainer.addSubview(toolbarNotch)

        progress.style = .spinning
        progress.controlSize = .regular
        progress.isDisplayedWhenStopped = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 4
        retryButton.target = self
        retryButton.action = #selector(reconnect)
        retryButton.isHidden = true
        statusOverlay.orientation = .vertical
        statusOverlay.alignment = .centerX
        statusOverlay.spacing = 12
        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addArrangedSubview(progress)
        statusOverlay.addArrangedSubview(statusLabel)
        statusOverlay.addArrangedSubview(retryButton)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)
        content.addSubview(toolbarContainer)
        content.addSubview(statusOverlay)
        toolbarTopConstraint = toolbarContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 8)
        toolbarLeadingConstraint = toolbarContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10)
        toolbarTrailingConstraint = toolbarContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10)
        toolbarWidthConstraint = toolbarContainer.widthAnchor.constraint(equalToConstant: 72)
        toolbarHeightConstraint = toolbarContainer.heightAnchor.constraint(equalToConstant: 32)
        toolbarContentConstraints = [
            toolbar.leadingAnchor.constraint(equalTo: toolbarContainer.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: toolbarContainer.trailingAnchor, constant: -8),
            toolbar.centerYAnchor.constraint(equalTo: toolbarContainer.centerYAnchor)
        ]
        canvasTopToToolbarConstraint = canvas.topAnchor.constraint(equalTo: toolbarContainer.bottomAnchor, constant: 8)
        canvasTopToContentConstraint = canvas.topAnchor.constraint(equalTo: content.topAnchor)
        NSLayoutConstraint.activate([
            toolbarTopConstraint!,
            toolbarLeadingConstraint!,
            toolbarTrailingConstraint!,
            toolbarHeightConstraint!,
            toolbarContainer.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toolbarContainer.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -20),
            toolbarNotch.centerXAnchor.constraint(equalTo: toolbarContainer.centerXAnchor),
            toolbarNotch.topAnchor.constraint(equalTo: toolbarContainer.topAnchor, constant: 2),
            toolbarNotch.widthAnchor.constraint(equalToConstant: 54),
            toolbarNotch.heightAnchor.constraint(equalToConstant: 4),
            canvasTopToToolbarConstraint!,
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusOverlay.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            statusOverlay.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            statusOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 40),
            statusOverlay.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -40),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 640)
        ])
        NSLayoutConstraint.activate(toolbarContentConstraints)
    }

    private func button(
        symbols: [String],
        fallbackName: NSImage.Name,
        tooltip: String,
        action: Selector
    ) -> NSButton {
        let image = symbols.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: tooltip)
        }.first ?? NSImage(named: fallbackName) ?? NSImage(named: NSImage.cautionName)!
        image.isTemplate = true
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .texturedRounded; button.toolTip = tooltip; button.setAccessibilityLabel(tooltip)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
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
            showStatus(NSLocalizedString("Disconnected", comment: "disconnected"), busy: false, retryable: true)
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
    @objc private func toggleFullScreen() { window?.toggleFullScreen(self) }
    @objc private func sendControlAltDelete() { session?.sendControlAltDelete() }

    func session(_ session: RDPSession, didChange state: RDPNativeSessionState, errorCode: UInt32) {
        guard self.session === session else { return }
        var fields: [String: DiagnosticValue] = [
            "sessionID": .privateText(sessionID.uuidString),
            "errorCode": .number(Double(errorCode))
        ]
        if state == .failed {
            if !session.lastErrorName.isEmpty {
                fields["freeRDPErrorName"] = .publicText(session.lastErrorName)
            }
            if !session.lastErrorDescription.isEmpty {
                fields["freeRDPErrorDescription"] = .publicText(session.lastErrorDescription)
            }
            if !session.lastNativeLogDetail.isEmpty {
                fields["nativeDetail"] = .privateText(session.lastNativeLogDetail)
            }
            fields["systemErrorCode"] = .number(Double(session.lastSystemErrorCode))
            fields["socketErrorCode"] = .number(Double(session.lastSocketErrorCode))
        }
        Task {
            await diagnostics.record(DiagnosticEvent(
                level: state == .failed ? .error : .info,
                category: .rdp,
                code: "RDP_STATE_\(state.rawValue)",
                message: Self.stateDescription(state),
                fields: fields
            ))
        }
        switch state {
        case .idle: showStatus(NSLocalizedString("Idle", comment: "idle"), busy: false)
        case .connecting: showStatus(NSLocalizedString("Negotiating TLS and authentication…", comment: "negotiating"), busy: true)
        case .connected:
            reconnectAttempt = 0
            showStatus(NSLocalizedString("Connected. Waiting for the remote desktop…", comment: "waiting for first frame"), busy: true)
            window?.makeFirstResponder(canvas)
            scheduleAdaptiveResize(immediate: true)
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
                showStatus(NSLocalizedString("Disconnected", comment: "disconnected"), busy: false, retryable: true)
            }
        case .failed:
            finish(session: session)
            handleFailure(errorCode)
        @unknown default: showStatus(NSLocalizedString("Unknown session state", comment: "unknown"), busy: false)
        }
    }

    func session(_ session: RDPSession, didReceiveFrame frame: Data, width: UInt32, height: UInt32, stride: UInt32) {
        guard self.session === session else { return }
        guard canvas.updateFrame(frame, width: Int(width), height: Int(height), stride: Int(stride)) else { return }
        let sizeChanged = width != lastRemoteFrameWidth || height != lastRemoteFrameHeight
        lastRemoteFrameWidth = width
        lastRemoteFrameHeight = height
        if sizeChanged { updateRemoteSizeLabel() }
        if let requested = requestedAdaptiveMetrics,
           requested.width == width,
           requested.height == height {
            requestedAdaptiveMetrics = nil
            adaptiveRetryCount = 0
            adaptiveConfirmationTask?.cancel()
            adaptiveConfirmationTask = nil
            updateRemoteSizeLabel()
            recordAdaptiveDisplayEvent(
                level: .info,
                code: "RDP_RESIZE_CONFIRMED",
                message: "The remote frame confirmed the requested desktop size.",
                metrics: requested
            )
        }
        progress.stopAnimation(nil)
        retryButton.isHidden = true
        statusOverlay.isHidden = true
    }

    func sessionDidActivateDisplayControl(_ session: RDPSession) {
        guard self.session === session else { return }
        displayControlActivated = true
        lastAdaptiveMetrics = nil
        lastResizeRejectionMetrics = nil
        recordAdaptiveDisplayEvent(
            level: .info,
            code: "RDP_DISPLAY_CONTROL_ACTIVE",
            message: "The server activated the RDP Display Control channel."
        )
        scheduleAdaptiveResize(immediate: true)
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
        fullscreenToolbarCollapseTask?.cancel()
        fullscreenToolbarCollapseTask = nil
        adaptiveResizeGeneration &+= 1
        adaptiveResizeTask?.cancel()
        adaptiveResizeTask = nil
        adaptiveConfirmationTask?.cancel()
        adaptiveConfirmationTask = nil
        clearEphemeralCredentials()
        retryTask?.cancel(); retryTask = nil
        connectTask?.cancel(); connectTask = nil
        disconnect()
        onClose(sessionID)
    }

    func windowDidResize(_ notification: Notification) {
        scheduleAdaptiveResize()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        setFullscreenToolbarPresentation(enabled: true, expanded: false)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        setFullscreenToolbarPresentation(enabled: false, expanded: true)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleAdaptiveResize(immediate: true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        setFullscreenToolbarPresentation(enabled: true, expanded: false)
        scheduleAdaptiveResize(immediate: true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        setFullscreenToolbarPresentation(enabled: false, expanded: true)
        scheduleAdaptiveResize(immediate: true)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        scheduleAdaptiveResize(immediate: true)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        scheduleAdaptiveResize(immediate: true)
    }

    private func finish(session finishedSession: RDPSession) {
        guard session === finishedSession else { return }
        finishedSession.delegate = nil
        session = nil
        connectTask = nil
        adaptiveResizeGeneration &+= 1
        adaptiveResizeTask?.cancel()
        adaptiveResizeTask = nil
        adaptiveConfirmationTask?.cancel()
        adaptiveConfirmationTask = nil
        lastAdaptiveMetrics = nil
        requestedAdaptiveMetrics = nil
        adaptiveRetryCount = 0
        displayControlActivated = false
        lastResizeRejectionMetrics = nil
        lastRemoteFrameWidth = 0
        lastRemoteFrameHeight = 0
        updateRemoteSizeLabel()
        releaseConnectionResources()
    }

    private func setFullscreenToolbarPresentation(enabled: Bool, expanded: Bool) {
        guard let content = window?.contentView else { return }
        isSessionFullScreen = enabled
        fullscreenToolbarCollapseTask?.cancel()
        fullscreenToolbarCollapseTask = nil

        let horizontalConstraints = [
            toolbarLeadingConstraint,
            toolbarTrailingConstraint,
            toolbarWidthConstraint,
            canvasTopToToolbarConstraint,
            canvasTopToContentConstraint
        ].compactMap { $0 }
        NSLayoutConstraint.deactivate(horizontalConstraints)
        NSLayoutConstraint.deactivate(toolbarContentConstraints)

        if enabled {
            NSLayoutConstraint.activate([
                toolbarWidthConstraint,
                canvasTopToContentConstraint
            ].compactMap { $0 })
        } else {
            NSLayoutConstraint.activate([
                toolbarLeadingConstraint,
                toolbarTrailingConstraint,
                canvasTopToToolbarConstraint
            ].compactMap { $0 })
        }
        toolbarTopConstraint?.constant = enabled ? 0 : 8

        let showContent = !enabled || expanded
        if showContent {
            NSLayoutConstraint.activate(toolbarContentConstraints)
        }
        toolbar.isHidden = !showContent
        toolbarNotch.isHidden = showContent
        toolbarWidthConstraint?.constant = expanded ? 336 : 72
        toolbarHeightConstraint?.constant = enabled ? (expanded ? 42 : 8) : 32
        toolbarContainer.layer?.cornerRadius = enabled ? 6 : 0
        toolbarContainer.layer?.backgroundColor = enabled
            ? NSColor(calibratedWhite: 0.04, alpha: 0.9).cgColor
            : NSColor.clear.cgColor
        toolbar.arrangedSubviews.compactMap { $0 as? NSButton }.forEach {
            $0.contentTintColor = enabled ? .white : .labelColor
        }
        remoteSizeLabel.textColor = enabled ? .white : .secondaryLabelColor
        content.layoutSubtreeIfNeeded()
    }

    private func showFullscreenToolbar() {
        fullscreenToolbarCollapseTask?.cancel()
        fullscreenToolbarCollapseTask = nil
        setFullscreenToolbarPresentation(enabled: true, expanded: true)
    }

    private func scheduleFullscreenToolbarCollapse() {
        fullscreenToolbarCollapseTask?.cancel()
        fullscreenToolbarCollapseTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) }
            catch { return }
            guard let self, self.isSessionFullScreen else { return }
            self.fullscreenToolbarCollapseTask = nil
            self.setFullscreenToolbarPresentation(enabled: true, expanded: false)
        }
    }

    private func currentAdaptiveMetrics() -> AdaptiveDesktopMetrics? {
        window?.contentView?.layoutSubtreeIfNeeded()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return AdaptiveDisplaySizing.metrics(
            canvasSizeInPoints: canvas.bounds.size,
            backingScaleFactor: scale
        )
    }

    private func scheduleAdaptiveResize(immediate: Bool = false) {
        guard profile.display.scaleMode == .dynamicResolution, !isClosing else { return }
        adaptiveResizeGeneration &+= 1
        let generation = adaptiveResizeGeneration
        adaptiveResizeTask?.cancel()
        adaptiveResizeTask = Task { [weak self] in
            if !immediate {
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return }
            }
            guard let self,
                  !Task.isCancelled,
                  self.adaptiveResizeGeneration == generation,
                  let session = self.session,
                  session.state == .connected,
                  let metrics = self.currentAdaptiveMetrics(),
                  metrics != self.lastAdaptiveMetrics else {
                if self?.adaptiveResizeGeneration == generation {
                    self?.adaptiveResizeTask = nil
                }
                return
            }
            let sent = session.requestDesktopResize(
                width: metrics.width,
                height: metrics.height,
                desktopScaleFactor: metrics.desktopScaleFactor,
                deviceScaleFactor: metrics.deviceScaleFactor,
                physicalWidth: metrics.physicalWidth,
                physicalHeight: metrics.physicalHeight
            )
            if sent {
                self.lastAdaptiveMetrics = metrics
                self.lastResizeRejectionMetrics = nil
                if self.requestedAdaptiveMetrics != metrics {
                    self.adaptiveRetryCount = 0
                }
                self.requestedAdaptiveMetrics = metrics
                self.updateRemoteSizeLabel()
                self.recordAdaptiveDisplayEvent(
                    level: .info,
                    code: "RDP_RESIZE_LAYOUT_SENT",
                    message: "A desktop layout update was sent through RDP Display Control.",
                    metrics: metrics
                )
                self.scheduleAdaptiveConfirmation(for: metrics)
            } else if self.lastResizeRejectionMetrics != metrics {
                self.lastResizeRejectionMetrics = metrics
                self.recordAdaptiveDisplayEvent(
                    level: .warning,
                    code: "RDP_RESIZE_LAYOUT_REJECTED",
                    message: "The desktop layout update could not be sent.",
                    metrics: metrics,
                    fields: ["displayControlActive": .boolean(self.displayControlActivated)]
                )
            }
            if self.adaptiveResizeGeneration == generation {
                self.adaptiveResizeTask = nil
            }
        }
    }

    private func scheduleAdaptiveConfirmation(for metrics: AdaptiveDesktopMetrics) {
        adaptiveConfirmationTask?.cancel()
        adaptiveConfirmationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) }
            catch { return }
            guard let self,
                  self.requestedAdaptiveMetrics == metrics,
                  !self.isClosing else { return }
            if self.lastRemoteFrameWidth == metrics.width,
               self.lastRemoteFrameHeight == metrics.height {
                self.requestedAdaptiveMetrics = nil
                self.adaptiveRetryCount = 0
                self.adaptiveConfirmationTask = nil
                self.updateRemoteSizeLabel()
                return
            }
            guard self.window?.inLiveResize != true,
                  self.currentAdaptiveMetrics() == metrics else {
                self.adaptiveConfirmationTask = nil
                return
            }
            guard self.adaptiveRetryCount < 3 else {
                self.requestedAdaptiveMetrics = nil
                self.adaptiveConfirmationTask = nil
                self.updateRemoteSizeLabel()
                self.recordAdaptiveDisplayEvent(
                    level: .warning,
                    code: "RDP_RESIZE_NOT_CONFIRMED",
                    message: "The remote frame did not confirm the requested desktop size after retries.",
                    metrics: metrics,
                    fields: [
                        "remoteWidth": .number(Double(self.lastRemoteFrameWidth)),
                        "remoteHeight": .number(Double(self.lastRemoteFrameHeight))
                    ]
                )
                return
            }
            self.adaptiveRetryCount += 1
            self.lastAdaptiveMetrics = nil
            self.adaptiveConfirmationTask = nil
            self.recordAdaptiveDisplayEvent(
                level: .info,
                code: "RDP_RESIZE_RETRY",
                message: "The desktop layout update is being retried.",
                metrics: metrics,
                fields: ["attempt": .number(Double(self.adaptiveRetryCount))]
            )
            self.scheduleAdaptiveResize(immediate: true)
        }
    }

    private func updateRemoteSizeLabel() {
        guard lastRemoteFrameWidth > 0, lastRemoteFrameHeight > 0 else {
            remoteSizeLabel.stringValue = ""
            remoteSizeLabel.isHidden = true
            return
        }
        if let requested = requestedAdaptiveMetrics,
           (requested.width != lastRemoteFrameWidth || requested.height != lastRemoteFrameHeight) {
            remoteSizeLabel.stringValue = "\(lastRemoteFrameWidth)x\(lastRemoteFrameHeight) > \(requested.width)x\(requested.height)"
        } else {
            remoteSizeLabel.stringValue = "\(lastRemoteFrameWidth)x\(lastRemoteFrameHeight)"
        }
        remoteSizeLabel.isHidden = false
    }

    private func recordAdaptiveDisplayEvent(
        level: DiagnosticLevel,
        code: String,
        message: String,
        metrics: AdaptiveDesktopMetrics? = nil,
        fields extraFields: [String: DiagnosticValue] = [:]
    ) {
        var fields = extraFields
        fields["sessionID"] = .privateText(sessionID.uuidString)
        if let metrics {
            fields["requestedWidth"] = .number(Double(metrics.width))
            fields["requestedHeight"] = .number(Double(metrics.height))
            fields["desktopScaleFactor"] = .number(Double(metrics.desktopScaleFactor))
        }
        Task {
            await diagnostics.record(DiagnosticEvent(
                level: level,
                category: .rdp,
                code: code,
                message: message,
                fields: fields
            ))
        }
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
            let summary = NSLocalizedString(
                RDPFailureClassifier.summary(for: errorCode),
                comment: "RDP failure summary"
            )
            showStatus(
                String(
                    format: NSLocalizedString("%@\nError code: 0x%08X", comment: "failure summary and code"),
                    summary,
                    errorCode
                ),
                busy: false,
                retryable: true
            )
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
           let stored = try await credentialStore.loadWithoutBlockingUI(reference: reference),
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
           let stored = try await credentialStore.loadWithoutBlockingUI(reference: reference),
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
           let stored = try await credentialStore.loadWithoutBlockingUI(reference: reference),
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

    private func showStatus(_ text: String, busy: Bool, retryable: Bool = false) {
        statusLabel.stringValue = text
        statusOverlay.isHidden = false
        retryButton.isHidden = !retryable
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

extension RDPConnectionConfiguration {
    func configureServerAddress(target: TargetIdentity, connectionEndpoint: Endpoint) {
        connectionHost = connectionEndpoint.host
        connectionPort = connectionEndpoint.port
        serverName = target.endpoint.host
        certificateName = target.certificateName
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
