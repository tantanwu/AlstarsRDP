# ADR-001: Pin FreeRDP 3.30.0 as the validation candidate

Status: Accepted for M0 validation, not yet approved for production  
Date: 2026-07-27

## Context

The client needs TLS, NLA/CredSSP, RD Gateway, graphics, dynamic resolution and virtual channels while retaining a macOS 11 deployment target and Universal 2 output. Floating dependencies make security response and reproducible builds impossible.

## Decision

Pin the validation candidate to FreeRDP tag `3.30.0`, resolved commit `6b107f0aadbabc47941c5a5b893b88c01792af6d`. Build arm64 and x86_64 independently with the same CMake features and deployment target, then combine only matching Mach-O outputs. Record provenance in `Vendor/manifest.json`.

Production acceptance remains conditional on macOS 11 Intel and Apple Silicon builds, Windows compatibility tests, dependency CVE review and signing/notarization validation.

## Consequences

Security updates require an explicit dependency change with compatibility evidence. The project owns any macOS 11 compatibility patches until it can move to a supported upstream version.

