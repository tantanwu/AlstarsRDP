import CoreGraphics
import RDPDomain

struct AdaptiveDesktopMetrics: Equatable {
    let width: UInt32
    let height: UInt32
    let desktopScaleFactor: UInt32
    let deviceScaleFactor: UInt32
    let physicalWidth: UInt32
    let physicalHeight: UInt32
}

enum AdaptiveDisplaySizing {
    static let minimumDimension: CGFloat = 200
    static let maximumDimension: CGFloat = 8_192
    static let pointsPerInch: CGFloat = 96

    static func metrics(
        canvasSizeInPoints: CGSize,
        backingScaleFactor: CGFloat
    ) -> AdaptiveDesktopMetrics? {
        guard canvasSizeInPoints.width.isFinite,
              canvasSizeInPoints.height.isFinite,
              backingScaleFactor.isFinite,
              canvasSizeInPoints.width > 0,
              canvasSizeInPoints.height > 0,
              backingScaleFactor > 0 else { return nil }

        let rawWidth = canvasSizeInPoints.width * backingScaleFactor
        let rawHeight = canvasSizeInPoints.height * backingScaleFactor
        let area = rawWidth * rawHeight
        let dimensionScale = min(
            1,
            maximumDimension / rawWidth,
            maximumDimension / rawHeight
        )
        let areaScale = area > CGFloat(DisplayConfiguration.maximumPixelCount)
            ? sqrt(CGFloat(DisplayConfiguration.maximumPixelCount) / area)
            : 1
        let limitScale = min(dimensionScale, areaScale)

        var width = max(minimumDimension, floor(rawWidth * limitScale))
        let height = min(maximumDimension, max(minimumDimension, floor(rawHeight * limitScale)))
        width -= width.truncatingRemainder(dividingBy: 2)

        let effectivePointWidth = width / backingScaleFactor
        let effectivePointHeight = height / backingScaleFactor
        let millimetersPerInch: CGFloat = 25.4
        let physicalWidth = UInt32(clamping: Int((effectivePointWidth / pointsPerInch * millimetersPerInch).rounded()))
        let physicalHeight = UInt32(clamping: Int((effectivePointHeight / pointsPerInch * millimetersPerInch).rounded()))
        let desktopScaleFactor = UInt32(clamping: min(
            500,
            max(100, Int((backingScaleFactor * 100).rounded()))
        ))

        return AdaptiveDesktopMetrics(
            width: UInt32(width),
            height: UInt32(height),
            desktopScaleFactor: desktopScaleFactor,
            deviceScaleFactor: 100,
            physicalWidth: min(10_000, max(10, physicalWidth)),
            physicalHeight: min(10_000, max(10, physicalHeight))
        )
    }
}
