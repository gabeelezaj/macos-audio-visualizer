import MetalKit
import SwiftUI

/// Hosts the `MTKView` that the renderer draws into.
struct MetalView: NSViewRepresentable {
    let renderer: Renderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        // Half-float target + extended-linear colour space lets highlights run past
        // 1.0 into XDR headroom instead of clipping to white.
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        view.framebufferOnly = true
        view.depthStencilPixelFormat = .invalid
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = renderer
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}

/// Creates the renderer once and surfaces a compile failure instead of crashing.
@MainActor
final class RenderHost: ObservableObject {
    @Published private(set) var renderer: Renderer?
    @Published private(set) var error: String?

    init() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.noDevice }
            let source = try ShaderLoader.source()
            renderer = try Renderer(device: device, shaderSource: source, pixelFormat: .rgba16Float)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
