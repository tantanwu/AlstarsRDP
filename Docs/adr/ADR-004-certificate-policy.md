# ADR-004: Require explicit decisions for unknown and changed certificates

Status: Accepted  
Date: 2026-07-27

TLS and NLA are enabled and legacy RDP Security is disabled. Valid system-trusted certificates connect without prompting through FreeRDP. Unknown certificates present host, port, subject, issuer and fingerprint with reject, trust once and trust-and-store choices. Changed certificates use a critical warning. There is no global ignore-certificate switch.

