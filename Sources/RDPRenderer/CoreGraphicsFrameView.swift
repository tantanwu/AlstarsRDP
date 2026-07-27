import AppKit
import RDPDomain

public final class CoreGraphicsFrameView: NSView {
    private var image: CGImage?
    private var frameSize = CGSize.zero
    public var scaleMode: DisplayConfiguration.ScaleMode = .fit {
        didSet { needsDisplay = true }
    }

    public override var isFlipped: Bool { false }

    public func updateFrame(_ data: Data, width: Int, height: Int, stride: Int) {
        guard FrameBufferValidation.isValid(
                  data: data,
                  width: width,
                  height: height,
                  stride: stride
              ),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return }
        self.image = image
        frameSize = CGSize(width: width, height: height)
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
        bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let destination = fittedRect()
        context.saveGState()
        context.translateBy(x: destination.minX, y: destination.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: destination.size))
        context.restoreGState()
    }

    private func fittedRect() -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return bounds }
        let scale = scaleMode == .actualSize ? 1 : min(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let size = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}
