import Foundation

struct DisplayResolutionPreset: Equatable {
    let width: UInt32
    let height: UInt32

    var title: String { "\(width) x \(height)" }

    static let common: [DisplayResolutionPreset] = [
        DisplayResolutionPreset(width: 1_280, height: 720),
        DisplayResolutionPreset(width: 1_440, height: 900),
        DisplayResolutionPreset(width: 1_600, height: 900),
        DisplayResolutionPreset(width: 1_920, height: 1_080),
        DisplayResolutionPreset(width: 2_560, height: 1_440),
        DisplayResolutionPreset(width: 3_840, height: 2_160)
    ]

    static func index(width: UInt32, height: UInt32) -> Int? {
        common.firstIndex { $0.width == width && $0.height == height }
    }
}
