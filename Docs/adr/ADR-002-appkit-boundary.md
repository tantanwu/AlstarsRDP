# ADR-002: Use AppKit for the macOS 11 application shell

Status: Accepted  
Date: 2026-07-27

AppKit owns windows, focus, keyboard, pointer, menus and accessibility. SwiftUI is not used in the session surface because macOS 11-era SwiftUI does not provide the input and window control required by a remote desktop client. Swift application code never imports FreeRDP C types; `RDPBridge` is the Objective-C++ boundary.

