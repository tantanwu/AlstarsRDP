# ADR-006: Use one serial FreeRDP worker per session for the first implementation

Status: Provisional  
Date: 2026-07-27

Each `RDPSession` owns one serial queue, one FreeRDP context and an explicit cancellation path. UI callbacks run on the main queue. Protocol types remain behind Objective-C++. This provides deterministic lifecycle management with low frame-transfer overhead.

XPC process isolation is still required as an M1 prototype and security decision. This ADR does not close M1-09.

