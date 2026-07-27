# RemoteDesktop for macOS

Native macOS 11+ RDP client with direct, SOCKS5 (hostname, IPv4, and IPv6 targets), HTTP CONNECT, HTTPS proxy, and RD Gateway routes. The application uses AppKit for desktop interaction, Metal for frame presentation, macOS Keychain for secrets, SQLite for versioned profiles, and FreeRDP for the RDP protocol.

The authoritative scope and progress tracker is [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md). Architecture decisions live in `Docs/adr`. Enterprise administrators should also read [Docs/enterprise/MDM_CONFIGURATION.md](Docs/enterprise/MDM_CONFIGURATION.md).

## Prerequisites

- macOS 11 or newer
- Xcode with the macOS 11 SDK deployment target available
- CMake 3.25+, Ninja, pkg-config, and XcodeGen
- A universal FreeRDP build produced by `Tools/build-freerdp.sh`

## Bootstrap

```bash
./Tools/bootstrap-macos.sh
./Tools/build-freerdp.sh
xcodegen generate
xcodebuild -project RemoteDesktop.xcodeproj -scheme RemoteDesktop \
  -configuration Debug -destination 'platform=macOS' build
```

Run unit tests with `./Tools/test.sh`. Signing and notarization require a local `Config/Signing.xcconfig`; secrets are never stored in this repository.

On Windows, repository metadata and localization can be checked without a macOS toolchain:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Tools/validate-repository.ps1
```

This static check does not replace the macOS build, unit tests, Universal 2 verification, or Windows interoperability tests.

Release packaging is intentionally separate from compilation:

```bash
./Tools/archive.sh
DEVELOPER_ID_APPLICATION='Developer ID Application: Example Corp (TEAMID)' ./Tools/package-dmg.sh
NOTARY_KEYCHAIN_PROFILE='remote-desktop-notary' ./Tools/notarize.sh Artifacts/RemoteDesktop.dmg
```

## Security

Do not report security vulnerabilities in a public issue. Follow [SECURITY.md](SECURITY.md). The client does not bypass Windows licensing, authentication, host policy, or RDS CAL requirements.

Profiles, backup archives, `.rdp` files, credential fields, security-scoped bookmarks, proxy requests, and decoded desktop frames have explicit size limits before parsing, storage, or presentation. Imported files are read incrementally up to their limit rather than loaded without a bound. Credentials remain in Keychain or session memory. Passwords and Keychain references are excluded from profile exports. Security-scoped folder bookmarks and legacy absolute paths are also removed from backups, so credentials and shared folders must be entered or selected again after restore. Managed preferences can cap reconnects and resource redirection, force display scaling, disable new credential saves, and prohibit private diagnostic exports.
