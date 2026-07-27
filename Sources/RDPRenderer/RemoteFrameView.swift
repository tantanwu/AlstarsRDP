import AppKit
import Metal
import RDPDomain

public final class RemoteFrameView: NSView {
    private let rendererView: NSView
    private let renderFrame: (Data, Int, Int, Int) -> Void
    private var frameSize = CGSize.zero
    private let scaleMode: DisplayConfiguration.ScaleMode

    public var onMouse: ((NSEvent, CGPoint, Bool, Int, Bool) -> Void)?
    public var onScroll: ((NSEvent, CGPoint) -> Void)?
    public var onKey: ((NSEvent, Bool) -> Void)?
    public var onFlagsChanged: ((NSEvent) -> Void)?
    public var onFocusLost: (() -> Void)?
    public var capturesCommandKeyEquivalents = false

    public init(scaleMode: DisplayConfiguration.ScaleMode) {
        self.scaleMode = scaleMode
        if let metal = MetalFrameView.make(frame: .zero) {
            metal.scaleMode = scaleMode
            rendererView = metal
            renderFrame = { [weak metal] data, width, height, stride in
                metal?.updateFrame(data, width: width, height: height, stride: stride)
            }
        } else {
            let coreGraphics = CoreGraphicsFrameView(frame: .zero)
            coreGraphics.scaleMode = scaleMode
            rendererView = coreGraphics
            renderFrame = { [weak coreGraphics] data, width, height, stride in
                coreGraphics?.updateFrame(data, width: width, height: height, stride: stride)
            }
        }
        super.init(frame: .zero)
        rendererView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rendererView)
        NSLayoutConstraint.activate([
            rendererView.topAnchor.constraint(equalTo: topAnchor),
            rendererView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rendererView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rendererView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var acceptsFirstResponder: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    public func updateFrame(_ data: Data, width: Int, height: Int, stride: Int) {
        guard FrameBufferValidation.isValid(
            data: data,
            width: width,
            height: height,
            stride: stride
        ) else { return }
        frameSize = CGSize(width: width, height: height)
        renderFrame(data, width, height, stride)
    }

    public func remotePoint(for event: NSEvent) -> CGPoint {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        let local = convert(event.locationInWindow, from: nil)
        let fitted = fittedRect()
        let safeWidth = max(fitted.width, 1)
        let safeHeight = max(fitted.height, 1)
        let maxX = max(frameSize.width - 1, 0)
        let maxY = max(frameSize.height - 1, 0)
        let x = min(max((local.x - fitted.minX) / safeWidth, 0), 1) * maxX
        let y = min(max((fitted.maxY - local.y) / safeHeight, 0), 1) * maxY
        return CGPoint(x: x, y: y)
    }

    public override func mouseMoved(with event: NSEvent) { onMouse?(event, remotePoint(for: event), false, 0, true) }
    public override func mouseDragged(with event: NSEvent) { onMouse?(event, remotePoint(for: event), true, 1, true) }
    public override func rightMouseDragged(with event: NSEvent) { onMouse?(event, remotePoint(for: event), true, 2, true) }
    public override func otherMouseDragged(with event: NSEvent) { onMouse?(event, remotePoint(for: event), true, 3, true) }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onMouse?(event, remotePoint(for: event), true, 1, false) }
    public override func mouseUp(with event: NSEvent) { onMouse?(event, remotePoint(for: event), false, 1, false) }
    public override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onMouse?(event, remotePoint(for: event), true, 2, false) }
    public override func rightMouseUp(with event: NSEvent) { onMouse?(event, remotePoint(for: event), false, 2, false) }
    public override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onMouse?(event, remotePoint(for: event), true, 3, false) }
    public override func otherMouseUp(with event: NSEvent) { onMouse?(event, remotePoint(for: event), false, 3, false) }
    public override func scrollWheel(with event: NSEvent) { onScroll?(event, remotePoint(for: event)) }
    public override func keyDown(with event: NSEvent) { onKey?(event, true) }
    public override func keyUp(with event: NSEvent) { onKey?(event, false) }
    public override func flagsChanged(with event: NSEvent) { onFlagsChanged?(event) }
    public override func resignFirstResponder() -> Bool { onFocusLost?(); return super.resignFirstResponder() }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard capturesCommandKeyEquivalents, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        onKey?(event, true)
        onKey?(event, false)
        return true
    }

    private func fittedRect() -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return bounds }
        let scale = scaleMode == .actualSize ? 1 : min(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let size = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}
