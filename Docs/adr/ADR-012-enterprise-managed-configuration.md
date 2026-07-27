# ADR-012: Versioned profile exchange and enterprise managed configuration

Status: Under review; managed policy is implemented in source but not accepted for production  
Date: 2026-07-27

## Context

Profiles must be portable without exporting credentials, while enterprise deployments need centrally enforced limits that imported data, stale UI state, or stored user defaults cannot bypass. macOS MDM commonly delivers application policy through the managed configuration dictionary or forced preferences.

## Decision

Keep profile backup and restore in a versioned JSON archive with explicit schema and size validation. Export only non-secret profile fields; Keychain material and credential references are never portable credentials.

Read enterprise policy from `com.apple.configuration.managed`, with forced direct preferences taking precedence. Policy may force automatic reconnect behavior and scale mode, cap reconnect attempts and redirection, disable new credential saves, and disable private diagnostic export. Enforce policy when settings are loaded, when profiles are saved, and again immediately before connection. Preserve the user's underlying settings where possible so removing a temporary policy restores their prior choices.

Unknown keys, invalid types, unsupported enum values, and out-of-range integers are ignored. Policy parsing must not coerce strings or numeric values into booleans.

## Consequences

Administrators receive deterministic, device-managed controls without secrets in configuration profiles. UI controls must expose forced state and cannot be the sole enforcement boundary. Every policy change requires parser tests, bypass tests, a macOS 11 build, and validation in a test MDM tenant before this ADR can be accepted.

The current development bundle identifier is not a production contract. Deployment documentation must be updated when the final identifier is approved.

## Validation status

Parser, effective-settings, redirection-cap, credential-reference removal, and diagnostic-export tests are authored. They have not run on macOS, and no real MDM delivery/removal evidence exists yet.
