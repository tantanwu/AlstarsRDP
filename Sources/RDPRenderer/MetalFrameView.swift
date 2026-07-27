import AppKit
import MetalKit
import RDPDomain

public final class MetalFrameView: MTKView, MTKViewDelegate {
    private struct Vertex {
        var position: SIMD2<Float>
        var texture: SIMD2<Float>
    }

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var frameTexture: MTLTexture?
    private var vertices: [Vertex] = []
    private var frameSize = CGSize.zero
    public var scaleMode: DisplayConfiguration.ScaleMode = .fit {
        didSet { updateVertices(); setNeedsDisplay(bounds) }
    }

    public var onMouse: ((NSEvent, CGPoint, Bool, Int) -> Void)?
    public var onScroll: ((NSEvent, CGPoint) -> Void)?
    public var onKey: ((NSEvent, Bool) -> Void)?
    public var onFlagsChanged: ((NSEvent) -> Void)?
    public var onFocusLost: (() -> Void)?

    public static func make(frame frameRect: NSRect, device requestedDevice: MTLDevice? = nil) -> MetalFrameView? {
        guard let device = requestedDevice ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VIn { packed_float2 position; packed_float2 texture; };
        struct VOut { float4 position [[position]]; float2 texture; };
        vertex VOut vertex_main(uint id [[vertex_id]], const device VIn *vertices [[buffer(0)]]) {
          VOut out; out.position = float4(vertices[id].position, 0, 1); out.texture = vertices[id].texture; return out;
        }
        fragment float4 fragment_main(VOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
          constexpr sampler s(filter::linear, address::clamp_to_edge); return image.sample(s, in.texture);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
            descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            return MetalFrameView(
                frame: frameRect,
                device: device,
                commandQueue: queue,
                pipeline: pipeline
            )
        } catch {
            return nil
        }
    }

    private init(
        frame frameRect: NSRect,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        pipeline: MTLRenderPipelineState
    ) {
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.06, 0.065, 0.07, 1)
        framebufferOnly = true
        enableSetNeedsDisplay = true
        isPaused = true
        delegate = self
    }

    public required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var acceptsFirstResponder: Bool { true }

    public func updateFrame(_ data: Data, width: Int, height: Int, stride: Int) {
        guard FrameBufferValidation.isValid(
            data: data,
            width: width,
            height: height,
            stride: stride
        ) else { return }
        if frameTexture?.width != width || frameTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            frameTexture = device?.makeTexture(descriptor: descriptor)
        }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            frameTexture?.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: base, bytesPerRow: stride
            )
        }
        frameSize = CGSize(width: width, height: height)
        updateVertices()
        setNeedsDisplay(bounds)
    }

    public func remotePoint(for event: NSEvent) -> CGPoint {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        let local = convert(event.locationInWindow, from: nil)
        let fitted = fittedRect()
        let safeWidth = max(fitted.width, 1)
        let safeHeight = max(fitted.height, 1)
        let x = min(max((local.x - fitted.minX) / safeWidth, 0), 1) * max(frameSize.width - 1, 0)
        let y = min(max((fitted.maxY - local.y) / safeHeight, 0), 1) * max(frameSize.height - 1, 0)
        return CGPoint(x: x, y: y)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { updateVertices() }

    public func draw(in view: MTKView) {
        guard let texture = frameTexture, let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable, let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass), !vertices.isEmpty else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    public override func mouseMoved(with event: NSEvent) { onMouse?(event, remotePoint(for: event), false, 0) }
    public override func mouseDragged(with event: NSEvent) { onMouse?(event, remotePoint(for: event), true, 1) }
    public override func rightMouseDragged(with event: NSEvent) { onMouse?(event, remotePoint(for: event), true, 2) }
    public override func otherMouseDragged(with event: NSEvent) { onMouse?(event, remotePoint(for: event), true, 3) }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onMouse?(event, remotePoint(for: event), true, 1) }
    public override func mouseUp(with event: NSEvent) { onMouse?(event, remotePoint(for: event), false, 1) }
    public override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onMouse?(event, remotePoint(for: event), true, 2) }
    public override func rightMouseUp(with event: NSEvent) { onMouse?(event, remotePoint(for: event), false, 2) }
    public override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onMouse?(event, remotePoint(for: event), true, 3) }
    public override func otherMouseUp(with event: NSEvent) { onMouse?(event, remotePoint(for: event), false, 3) }
    public override func scrollWheel(with event: NSEvent) { onScroll?(event, remotePoint(for: event)) }
    public override func keyDown(with event: NSEvent) { onKey?(event, true) }
    public override func keyUp(with event: NSEvent) { onKey?(event, false) }
    public override func flagsChanged(with event: NSEvent) { onFlagsChanged?(event) }
    public override func resignFirstResponder() -> Bool { onFocusLost?(); return super.resignFirstResponder() }

    private func fittedRect() -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return bounds }
        let scale = scaleMode == .actualSize ? 1 : min(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let size = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func updateVertices() {
        guard bounds.width > 0, bounds.height > 0, frameSize.width > 0 else { vertices = []; return }
        let fitted = fittedRect()
        let left = Float(fitted.minX / bounds.width * 2 - 1)
        let right = Float(fitted.maxX / bounds.width * 2 - 1)
        let bottom = Float(fitted.minY / bounds.height * 2 - 1)
        let top = Float(fitted.maxY / bounds.height * 2 - 1)
        vertices = [
            Vertex(position: SIMD2(left, bottom), texture: SIMD2(0, 1)),
            Vertex(position: SIMD2(right, bottom), texture: SIMD2(1, 1)),
            Vertex(position: SIMD2(left, top), texture: SIMD2(0, 0)),
            Vertex(position: SIMD2(right, top), texture: SIMD2(1, 0))
        ]
    }
}
