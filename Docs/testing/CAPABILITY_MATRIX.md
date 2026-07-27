# Capability Matrix

Last updated: 2026-07-27

| Capability | Implemented in source | Automated test | macOS 11 verified | Production approved |
|---|---:|---:|---:|---:|
| Profile validation and JSON safety | Yes | Yes | No | No |
| Session state machine | Yes | Yes | No | No |
| SOCKS5 no-auth/user-password | Yes | Parser tests | No | No |
| SOCKS5 hostname/IPv4/IPv6 address encoding | Yes | Protocol tests authored | No | No |
| HTTP CONNECT Basic | Yes | Parser tests | No | No |
| HTTPS proxy TLS | Yes | Parser tests | No | No |
| Temporary proxy credentials and explicit prompt cancellation | Yes | Domain/UI-flow tests authored | No | No |
| Loopback tunnel with generation-based cancellation | Yes | No | No | No |
| Connection path probe and timeout | Yes | No | No | No |
| SQLite profiles and migration | Yes | Yes | No | No |
| Profile tag search and optimistic concurrency | Yes | Tests authored | No | No |
| Atomic database/WAL/SHM quarantine recovery | Yes | Filesystem test authored | No | No |
| Versioned profile backup/restore | Yes | Yes | No | No |
| Keychain credentials and two-phase profile commit | Yes | Transaction tests | No | No |
| Serialized profile/Keychain mutation and restore cleanup | Yes | Concurrency and cleanup tests authored | No | No |
| Profile deletion and post-commit Keychain cleanup transaction | Yes | Fault-injection tests authored | No | No |
| RDP file import/export without secrets | Yes | Yes | No | No |
| FreeRDP TLS/NLA | Yes | No | No | No |
| RD Gateway | Yes | No | No | No |
| Metal frame presentation | Yes | Frame validation tests authored | No | No |
| Core Graphics rendering fallback | Yes | Frame validation tests authored | No | No |
| Latest-frame coalescing and 256 MiB frame limit | Yes | Boundary tests authored | No | No |
| Keyboard modes/mouse drag/scroll | Yes | No | No | No |
| Multi-session identity/callback isolation | Yes | No | No | No |
| Bounded reconnect/network-path handling | Yes | Domain tests | No | No |
| Diagnostics preview/redacted export | Yes | Redaction tests | No | No |
| Enterprise MDM policy and forced settings | Yes | Policy tests authored | No | No |
| Bounded profile/archive/RDP file, credential, and bookmark inputs | Yes; file reads are streaming and capped | Boundary tests authored | No | No |
| Unified direct/proxy/gateway route validation | Yes | Domain tests authored | No | No |
| English/Simplified Chinese resources | Yes | No | No | No |
| Repository encoding/manifest/localization validation | Yes | PowerShell gate passed on Windows | No | No |
| Per-architecture Universal 2 runtime dependency closure | Script authored | Not run | No | No |
| AppKit/renderer Xcode test step | Workflow authored | Not run | No | No |
| Clipboard | FreeRDP setting only | No | No | No |
| Audio playback/capture | FreeRDP setting only | No | No | No |
| User-selected folder authorization | Yes; channel registration blocked | No | No | No |
| Printer/smart-card redirection | FreeRDP setting only | No | No | No |
| Camera redirection | No | No | No | No |
| Signing/notarization/update | Scripts only | No | No | No |

“Implemented in source” is not equivalent to a completed requirement. “Tests authored” means the test source and Xcode workflow step exist but have not run on the current Windows host. `DEVELOPMENT_PLAN.md` changes to `已完成` only after the documented acceptance evidence exists.
