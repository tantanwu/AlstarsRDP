import Foundation

public enum BoundedFileReadError: Error, Equatable, LocalizedError, Sendable {
    case tooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case let .tooLarge(limit): return "The file exceeds the \(limit)-byte read limit."
        }
    }
}

public enum BoundedFileReader {
    private static let chunkBytes = 64 * 1024

    /// Reads at most `maximumBytes + 1` bytes, so the size check cannot be
    /// bypassed by loading an arbitrarily large file before validation.
    public static func read(from url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw BoundedFileReadError.tooLarge(maximumBytes) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        result.reserveCapacity(min(maximumBytes, chunkBytes))

        while true {
            let remaining = maximumBytes - result.count
            let requested = remaining >= chunkBytes ? chunkBytes : remaining + 1
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else {
                return result
            }
            result.append(chunk)
            guard result.count <= maximumBytes else {
                throw BoundedFileReadError.tooLarge(maximumBytes)
            }
        }
    }
}
