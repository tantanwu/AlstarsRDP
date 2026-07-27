# Security Policy

## Supported versions

Security fixes are provided for the latest stable release and the active beta. Pre-release development builds are not suitable for production access.

## Reporting

Report suspected vulnerabilities privately to the security contact configured by the project owner. Until that address is assigned, do not attach credentials, packet captures, remote frames, or diagnostic archives to public issues.

Include the affected version, macOS version, connection route, reproduction steps, and whether secrets or remote content may have been exposed. The project targets acknowledgement within two business days, triage within five business days, and an expedited fix for critical issues.

## Security defaults

- TLS and NLA are required by default.
- Certificate errors require an explicit decision and certificate changes receive a stronger warning.
- Passwords are stored only in macOS Keychain.
- Drive, microphone, camera, printer, and smart-card redirection are disabled by default.
- Diagnostic logs exclude credentials, authentication headers, clipboard contents, remote frames, and file contents.

