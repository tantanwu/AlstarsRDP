import Foundation

enum FrameBufferValidation {
    static let maximumByteCount = 256 * 1024 * 1024

    static func isValid(
        data: Data,
        width: Int,
        height: Int,
        stride: Int
    ) -> Bool {
        guard width > 0, height > 0, stride > 0,
              width <= Int.max / 4,
              stride >= width * 4,
              height <= Int.max / stride else { return false }
        let requiredBytes = stride * height
        return requiredBytes <= maximumByteCount && data.count >= requiredBytes
    }
}
