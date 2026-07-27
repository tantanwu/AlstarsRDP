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
             0x0002_000D:
            return .retryable
        case 0x0002_000B:
            return .cancelled
        case 0x0002_0009,
             0x0002_000A,
             0x0002_000E ... 0x0002_0017:
            return .authentication
        default:
            return .terminal
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
