# ADR-003: Use a per-session loopback tunnel for general proxies

Status: Accepted for implementation, pending macOS network validation  
Date: 2026-07-27

## Decision

Direct and RD Gateway connections are owned by FreeRDP. SOCKS5 and HTTP/HTTPS CONNECT routes use a per-session `NWListener` bound only to `127.0.0.1` on an ephemeral port. The listener establishes an authenticated upstream tunnel and relays bytes bidirectionally.

FreeRDP receives the loopback address as `ServerHostname`, while `FreeRDP_CertificateName` remains the original target name. This preserves RDP certificate verification and keeps proxy parsing outside the protocol library. Proxy-side DNS is retained by sending the target domain in the SOCKS5 request.

## Consequences

Every listener and accepted connection must be cancelled on failure, user cancellation and window close. IPv6 loopback support is deferred until its dual-stack behavior is tested.

