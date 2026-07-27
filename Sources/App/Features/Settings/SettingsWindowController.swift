import AppKit
import Persistence
import RDPDomain

@MainActor
final class SettingsWindowController: NSWindowController {
    private let store: ApplicationSettingsStore
    private let reconnectButton = NSButton(checkboxWithTitle: NSLocalizedString("Allow automatic reconnect", comment: "allow reconnect"), target: nil, action: nil)
    private let attemptsField = NSTextField()
    private let scalePopup = NSPopUpButton()
    private let redirectionPopup = NSPopUpButton()

    init(store: ApplicationSettingsStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 270),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Settings", comment: "settings title")
        super.init(window: window)
        buildInterface()
        load()
        applyEnterprisePolicy()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        scalePopup.addItems(withTitles: [
            NSLocalizedString("Fit window", comment: "fit"),
            NSLocalizedString("Actual size", comment: "actual"),
            NSLocalizedString("Dynamic resolution", comment: "dynamic")
        ])
        redirectionPopup.addItems(withTitles: [
            NSLocalizedString("Secure", comment: "secure preset"),
            NSLocalizedString("Standard", comment: "standard preset"),
            NSLocalizedString("Complete", comment: "complete preset")
        ])
        let rows = NSStackView(views: [
            reconnectButton,
            row(NSLocalizedString("Default reconnect attempts", comment: "default reconnect attempts"), attemptsField),
            row(NSLocalizedString("Default display scaling", comment: "default scaling"), scalePopup),
            row(NSLocalizedString("Default redirection policy", comment: "default redirection"), redirectionPopup)
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: NSLocalizedString("Restore Defaults", comment: "restore defaults"), target: self, action: #selector(reset))
        let save = NSButton(title: NSLocalizedString("Save", comment: "save"), target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reset, NSView(), save])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            buttons.leadingAnchor.constraint(equalTo: rows.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: rows.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 220).isActive = true
        control.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func load() {
        let settings = store.load()
        reconnectButton.state = settings.automaticReconnectEnabled ? .on : .off
        attemptsField.integerValue = Int(settings.defaultReconnectAttempts)
        scalePopup.selectItem(at: settings.defaultScaleMode == .fit ? 0 : settings.defaultScaleMode == .actualSize ? 1 : 2)
        redirectionPopup.selectItem(at: settings.defaultRedirectionPreset == .secure ? 0 : settings.defaultRedirectionPreset == .standard ? 1 : 2)
    }

    private func applyEnterprisePolicy() {
        let policy = store.policy
        let managed = NSLocalizedString("Managed by your organization", comment: "managed setting tooltip")
        if policy.automaticReconnectEnabled != nil {
            reconnectButton.isEnabled = false
            reconnectButton.toolTip = managed
        }
        if policy.forcedScaleMode != nil {
            scalePopup.isEnabled = false
            scalePopup.toolTip = managed
        }
        if let maximumPreset = policy.maximumRedirectionPreset {
            let maximumIndex = maximumPreset == .secure ? 0 : maximumPreset == .standard ? 1 : 2
            for index in 0..<redirectionPopup.numberOfItems {
                redirectionPopup.item(at: index)?.isEnabled = index <= maximumIndex
            }
            redirectionPopup.toolTip = managed
        }
        if policy.maximumReconnectAttempts != nil {
            attemptsField.toolTip = managed
        }
    }

    @objc private func reset() {
        store.restoreDefaults()
        load()
    }

    @objc private func save() {
        var settings = store.loadStored()
        let effective = store.load()
        let policy = store.policy
        if policy.automaticReconnectEnabled == nil {
            settings.automaticReconnectEnabled = reconnectButton.state == .on
        }
        let selectedAttempts = UInt8(clamping: attemptsField.integerValue)
        if let maximumAttempts = policy.maximumReconnectAttempts {
            if selectedAttempts != effective.defaultReconnectAttempts {
                settings.defaultReconnectAttempts = min(selectedAttempts, maximumAttempts)
            }
        } else {
            settings.defaultReconnectAttempts = selectedAttempts
        }
        if policy.forcedScaleMode == nil {
            settings.defaultScaleMode = scalePopup.indexOfSelectedItem == 0
                ? .fit
                : scalePopup.indexOfSelectedItem == 1 ? .actualSize : .dynamicResolution
        }
        let selectedPreset: RedirectionPolicy.Preset = redirectionPopup.indexOfSelectedItem == 0
            ? .secure
            : redirectionPopup.indexOfSelectedItem == 1 ? .standard : .complete
        if let maximumPreset = policy.maximumRedirectionPreset {
            if selectedPreset != effective.defaultRedirectionPreset {
                settings.defaultRedirectionPreset = Self.minimum(selectedPreset, maximumPreset)
            }
        } else {
            settings.defaultRedirectionPreset = selectedPreset
        }
        do {
            try store.save(settings)
            window?.close()
        } catch {
            guard let window else { return }
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    private static func minimum(
        _ lhs: RedirectionPolicy.Preset,
        _ rhs: RedirectionPolicy.Preset
    ) -> RedirectionPolicy.Preset {
        let rank: (RedirectionPolicy.Preset) -> Int = { preset in
            switch preset {
            case .secure: return 0
            case .standard: return 1
            case .complete: return 2
            }
        }
        return rank(lhs) <= rank(rhs) ? lhs : rhs
    }
}
