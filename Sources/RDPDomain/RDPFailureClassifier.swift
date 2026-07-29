import Foundation

public enum RDPFailureDisposition: Equatable, Sendable {
    case retryable
    case authentication
    case cancelled
    case terminal
}

/// FreeRDP reserves 0x0002_0000 for client connection failures. Keeping the
/// classification in the domain layer makes retry policy deterministic and
/// prevents authentication failures from entering an automatic retry loop.
public enum RDPFailureClassifier {
    public static func disposition(for errorCode: UInt32) -> RDPFailureDisposition {
        switch errorCode {
        case 0x0002_0004 ... 0x0002_0008,
             0x0002_000C,
             0x0002_000D,
             0x0002_001C,
             0x0002_001D:
            return .retryable
        case 0x0002_000B:
            return .cancelled
        case 0x0002_0009,
             0x0002_000A,
             0x0002_000E ... 0x0002_001B:
            return .authentication
        default:
            return .terminal
        }
    }

    public static func summary(for errorCode: UInt32) -> String {
        switch errorCode {
        case 0x0002_0001:
            return "The RDP client components could not be initialized."
        case 0x0002_0002, 0x0002_0003:
            return "The RDP client session could not be initialized."
        case 0x0002_0004, 0x0002_0005:
            return "The target computer name could not be resolved."
        case 0x0002_0006, 0x0002_0007, 0x0002_000D:
            return "The target computer could not be reached."
        case 0x0002_0008, 0x0002_000C:
            return "TLS or RDP security negotiation failed."
        case 0x0002_0009, 0x0002_000A, 0x0002_000E ... 0x0002_001B:
            return "Windows authentication failed or the account cannot sign in remotely."
        case 0x0002_000B:
            return "The connection was cancelled."
        case 0x0002_001C:
            return "The remote desktop did not become ready in time."
        case 0x0002_001D:
            return "The target computer is still starting."
        default:
            return "The RDP connection failed."
        }
    }

    public static func summary(for errorCode: UInt32, route: RouteConfiguration) -> String {
        guard errorCode == 0x0002_0006 || errorCode == 0x0002_0007 || errorCode == 0x0002_000D else {
            return summary(for: errorCode)
        }
        switch route {
        case .socks5, .httpConnect:
            return "The selected proxy could not carry the RDP connection. It may block TCP port 3389 or RDP traffic."
        default:
            return summary(for: errorCode)
        }
    }
}

public enum ReconnectBackoff {
    public static func delayMilliseconds(forAttempt attempt: UInt8, policy: ReconnectPolicy) -> UInt32 {
        guard attempt > 0 else { return 0 }
        let shift = min(Int(attempt - 1), 31)
        let multiplied = UInt64(policy.initialDelayMilliseconds) << UInt64(shift)
        return UInt32(min(multiplied, UInt64(policy.maximumDelayMilliseconds)))
    }
}
