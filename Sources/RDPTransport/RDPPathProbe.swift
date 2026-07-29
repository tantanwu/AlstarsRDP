import Foundation
import Network

enum RDPPathProbeError: Error, Equatable, LocalizedError, Sendable {
    case peerClosed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .peerClosed:
            return NSLocalizedString(
                "The proxy path closed before the RDP server responded. The selected proxy may block TCP port 3389 or RDP traffic.",
                comment: "RDP route probe closed"
            )
        case .invalidResponse:
            return NSLocalizedString(
                "The target did not return a valid RDP negotiation response.",
                comment: "RDP route probe malformed response"
            )
        }
    }
}

enum RDPPathProbe {
    // TPKT + X.224 Connection Request + RDP Negotiation Request for TLS or NLA.
    static let connectionRequest = Data([
        0x03, 0x00, 0x00, 0x13,
        0x0E, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00
    ])

    static func verify(
        connection: NWConnection,
        prefetchedData: Data = Data()
    ) async throws {
        try await connection.sendAll(connectionRequest)
        var response = prefetchedData

        do {
            while response.count < 4 {
                guard let chunk = try await connection.receiveChunk(maximumLength: 4 - response.count) else {
                    throw RDPPathProbeError.peerClosed
                }
                response.append(chunk)
            }

            guard response[0] == 0x03, response[1] == 0x00 else {
                throw RDPPathProbeError.invalidResponse
            }
            let packetLength = (Int(response[2]) << 8) | Int(response[3])
            guard packetLength >= 11, packetLength <= Int(UInt16.max) else {
                throw RDPPathProbeError.invalidResponse
            }
            while response.count < packetLength {
                guard let chunk = try await connection.receiveChunk(maximumLength: packetLength - response.count) else {
                    throw RDPPathProbeError.peerClosed
                }
                response.append(chunk)
            }
        } catch NetworkConnectionIOError.closed {
            throw RDPPathProbeError.peerClosed
        }

        try validateConnectionConfirm(Data(response.prefix((Int(response[2]) << 8) | Int(response[3]))))
    }

    static func validateConnectionConfirm(_ response: Data) throws {
        guard response.count >= 11,
              response[0] == 0x03,
              response[1] == 0x00 else {
            throw RDPPathProbeError.invalidResponse
        }
        let packetLength = (Int(response[2]) << 8) | Int(response[3])
        guard packetLength == response.count,
              Int(response[4]) + 5 == packetLength,
              response[5] == 0xD0 else {
            throw RDPPathProbeError.invalidResponse
        }
    }
}
