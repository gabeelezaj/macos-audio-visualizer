import Foundation
import Metal
import MetalKit
import simd

/// Must match `struct Uniforms` in Shaders.metal exactly (24 floats, then 4 float4s).
struct Uniforms {
    var resolution = SIMD2<Float>(1, 1)
    var time: Float = 0
    var dt: Float = 1.0 / 60
    var level: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    var beat: Float = 0
    var beatPhase: Float = 0
    var tempoPhase: Float = 0
    var bpm: Float = 0
    var sensitivity: Float = 1
    var trail: Float = 0
    var hue: Float = 0
    var edrScale: Float = 1
    var aspect: Float = 1
    var stereoWidth: Float = 0
    var balance: Float = 0
    var idle: Float = 0
    var spectrogramCursor: Float = 0
    var tempoConfidence: Float = 0
    var padding0: Float = 0
    var padding1: Float = 0
    var palette = (SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0),
                   SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 0))
}

private struct CompositeUniforms {
    var trail: Float = 0
    var edrScale: Float = 1
    var time: Float = 0
    var grain: Float = 0.010
    /// 0 = show scene A only, 1 = show scene B only. Drives mode crossfades.
    var transition: Float = 0
    var padding = SIMD3<Float>(repeating: 0)
}

enum RenderQuality: Int, CaseIterable, Identifiable, Codable {
    case automatic, full, balanced, performance

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .automatic: "Auto"
        case .full: "Full"
        case .balanced: "Balanced"
        case .performance: "Performance"
        }
    }

    /// Fraction of the drawable the visualization is rendered at before upscaling.
    func scale(forPixelCount pixels: Int) -> Float {
        switch self {
        case .full: return 1.0
        case .balanced: return 0.75
        case .performance: return 0.55
        case .automatic:
            // Above roughly 4K the fragment cost of eight fullscreen shaders starts
            // to bite; below it there is no reason not to render natively.
            if pixels > 9_000_000 { return 0.6 }
            if pixels > 4_500_000 { return 0.75 }
            return 1.0
        }
    }
}

enum RendererError: LocalizedError {
    case noDevice
    case missingShaderSource
    case shaderCompilation(String)
    case missingFunction(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: "This Mac has no Metal-capable GPU."
        case .missingShaderSource: "Shaders.metal is missing from the app bundle."
        case .shaderCompilation(let message): "Shader compilation failed:\n\(message)"
        case .missingFunction(let name): "Shader function '\(name)' was not found."
        }
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    static let spectrogramRows = 256
    /// Oversampled against the 512-sample waveform so the vectorscope trace is solid.
    static let stereoPointCount = 2048

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let vertexFunction: MTLFunction

    private var scenePipelines: [VisualMode: MTLRenderPipelineState] = [:]
    private var trailPipeline: MTLRenderPipelineState!
    private var presentPipeline: MTLRenderPipelineState!
    private var stereoPointPipeline: MTLRenderPipelineState!

    private var sceneTextures: [MTLTexture] = []      // [current, outgoing]
    private var historyTextures: [MTLTexture] = []
    private var historyIndex = 0
    private var renderSize = CGSize(width: 1, height: 1)
    private var drawableSize = CGSize(width: 1, height: 1)

    private let spectrumTexture: MTLTexture
    private let waveTexture: MTLTexture
    private let spectrogramTexture: MTLTexture
    private var spectrogramRow = 0
    private var spectrogramScratch = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    private var uniforms = Uniforms()
    private var startTime = CACurrentMediaTime()
    private var lastFrameTime = CACurrentMediaTime()

    // MARK: - Settings (written from the UI thread)
    var mode: VisualMode = .aurora {
        didSet { beginTransition(from: oldValue) }
    }
    var palette: Palette = Palette.all[0]
    var sensitivity: Float = 1
    var trail: Float = 0.2
    var colorDrift: Float = 0.35
    var edrEnabled = true
    var isPaused = false
    var quality: RenderQuality = .automatic {
        didSet { if quality != oldValue { allocateTargets(size: drawableSize) } }
    }

    /// Crossfade state: which mode is fading out, and how far along we are.
    private var outgoingMode: VisualMode?
    private var transition: Float = 1
    private let transitionDuration: Float = 0.8

    /// Supplies the latest analysis for a given frame duration, once per displayed frame.
    var frameProvider: ((Float) -> AudioFrame)?
    /// Reports measured frame rate back to the UI roughly twice a second.
    var onFrameRate: ((Double) -> Void)?
    private var frameCounter = 0
    private var frameRateClock = CACurrentMediaTime()

    // MARK: - Setup

    init(device: MTLDevice, shaderSource: String, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noDevice }
        commandQueue = queue

        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw RendererError.shaderCompilation(error.localizedDescription)
        }
        guard let vertex = library.makeFunction(name: "fullscreen_vertex") else {
            throw RendererError.missingFunction("fullscreen_vertex")
        }
        vertexFunction = vertex

        func makeDataTexture(_ width: Int, _ height: Int, _ format: MTLPixelFormat) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor)
        }
        // Both data textures carry left in .r and right in .g.
        guard let spectrum = makeDataTexture(SpectrumAnalyzer.bandCount, 1, .rg32Float),
              let wave = makeDataTexture(SpectrumAnalyzer.waveformCount, 1, .rg32Float),
              let spectrogram = makeDataTexture(SpectrumAnalyzer.bandCount, Self.spectrogramRows, .r32Float) else {
            throw RendererError.noDevice
        }
        spectrumTexture = spectrum
        waveTexture = wave
        spectrogramTexture = spectrogram

        super.init()

        assert(MemoryLayout<Uniforms>.stride == 160, "Uniforms layout drifted from the shader")
        trailPipeline = try makePipeline(fragment: "trail_fragment", pixelFormat: .rgba16Float)
        presentPipeline = try makePipeline(fragment: "present_fragment", pixelFormat: pixelFormat)
        stereoPointPipeline = try makeStereoPointPipeline()
        _ = try pipeline(for: mode)
    }

    private func makePipeline(fragment name: String, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw RendererError.missingFunction(name)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = name
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = function
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Additive point sprites, one per waveform sample.
    private func makeStereoPointPipeline() throws -> MTLRenderPipelineState {
        guard let vertex = library.makeFunction(name: "stereo_point_vertex") else {
            throw RendererError.missingFunction("stereo_point_vertex")
        }
        guard let fragment = library.makeFunction(name: "stereo_point_fragment") else {
            throw RendererError.missingFunction("stereo_point_fragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "stereo points"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Pipelines are built on first use so switching modes never stalls startup.
    private func pipeline(for mode: VisualMode) throws -> MTLRenderPipelineState {
        if let existing = scenePipelines[mode] { return existing }
        let state = try makePipeline(fragment: mode.fragmentFunction, pixelFormat: .rgba16Float)
        scenePipelines[mode] = state
        return state
    }

    /// Compiles every mode ahead of time so the first switch is glitch-free.
    func warmUp() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for mode in VisualMode.allCases { _ = try? self.pipeline(for: mode) }
        }
    }

    private func beginTransition(from previous: VisualMode) {
        guard previous != mode else { return }
        outgoingMode = previous
        transition = 0
    }

    // MARK: - Render targets

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        allocateTargets(size: size)
    }

    private func allocateTargets(size: CGSize) {
        drawableSize = size
        let pixels = Int(size.width * size.height)
        let scale = quality.scale(forPixelCount: pixels)
        let width = max(1, Int((size.width * CGFloat(scale)).rounded()))
        let height = max(1, Int((size.height * CGFloat(scale)).rounded()))
        renderSize = CGSize(width: width, height: height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        sceneTextures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        historyTextures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        historyIndex = 0
    }

    // MARK: - Frame

    func draw(in view: MTKView) {
        guard !isPaused,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        if sceneTextures.count < 2 || historyTextures.count < 2 {
            allocateTargets(size: view.drawableSize)
        }
        guard sceneTextures.count == 2, historyTextures.count == 2 else { return }

        let now = CACurrentMediaTime()
        let delta = min(0.1, now - lastFrameTime)
        lastFrameTime = now
        reportFrameRate(now: now)

        let audio = frameProvider?(Float(delta)) ?? AudioFrame.empty(bands: SpectrumAnalyzer.bandCount,
                                                                    waveform: SpectrumAnalyzer.waveformCount)
        upload(audio)
        updateUniforms(audio: audio, now: now, delta: delta, view: view)

        if transition < 1 {
            transition = min(1, transition + Float(delta) / transitionDuration)
            if transition >= 1 { outgoingMode = nil }
        }

        var composite = CompositeUniforms(trail: trail, edrScale: uniforms.edrScale,
                                          time: uniforms.time, grain: 0.010,
                                          transition: smoothstep(transition))

        // Pass 1 — the visualization(s). During a mode change both run, and the
        // trail pass blends them, so a switch dissolves instead of cutting.
        renderScene(mode, into: sceneTextures[0], commandBuffer: commandBuffer)
        if let outgoingMode {
            renderScene(outgoingMode, into: sceneTextures[1], commandBuffer: commandBuffer)
        }

        let previousHistory = historyTextures[historyIndex]
        let nextHistory = historyTextures[1 - historyIndex]
        historyIndex = 1 - historyIndex

        // Pass 2 — blend the (possibly crossfading) scene with the previous frame.
        let trailPass = MTLRenderPassDescriptor()
        trailPass.colorAttachments[0].texture = nextHistory
        trailPass.colorAttachments[0].loadAction = .clear
        trailPass.colorAttachments[0].storeAction = .store
        trailPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: trailPass) {
            encoder.setRenderPipelineState(trailPipeline)
            encoder.setFragmentBytes(&composite, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            encoder.setFragmentTexture(sceneTextures[0], index: 0)
            encoder.setFragmentTexture(previousHistory, index: 1)
            encoder.setFragmentTexture(outgoingMode == nil ? sceneTextures[0] : sceneTextures[1], index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // Pass 3 — tone map, upscale if we rendered below native, and present.
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.setRenderPipelineState(presentPipeline)
            encoder.setFragmentBytes(&composite, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            encoder.setFragmentTexture(nextHistory, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func renderScene(_ mode: VisualMode, into texture: MTLTexture,
                             commandBuffer: MTLCommandBuffer) {
        guard let scenePipeline = try? pipeline(for: mode) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        encoder.setRenderPipelineState(scenePipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(spectrumTexture, index: 0)
        encoder.setFragmentTexture(waveTexture, index: 1)
        encoder.setFragmentTexture(spectrogramTexture, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if mode.overlay == .stereoPoints {
            encoder.setRenderPipelineState(stereoPointPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setVertexTexture(waveTexture, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0,
                                   vertexCount: Self.stereoPointCount)
        }
        encoder.endEncoding()
    }

    private func updateUniforms(audio: AudioFrame, now: CFTimeInterval,
                                delta: CFTimeInterval, view: MTKView) {
        let width = Float(renderSize.width)
        let height = Float(renderSize.height)
        uniforms.resolution = SIMD2(width, height)
        uniforms.aspect = max(0.1, width / max(height, 1))
        uniforms.time = Float(now - startTime)
        uniforms.dt = Float(delta)
        uniforms.level = audio.level
        uniforms.bass = audio.bass
        uniforms.mid = audio.mid
        uniforms.treble = audio.treble
        uniforms.beat = audio.beat
        uniforms.beatPhase = audio.beatPhase
        uniforms.tempoPhase = audio.tempoPhase
        uniforms.bpm = audio.bpm
        uniforms.sensitivity = sensitivity
        uniforms.trail = trail
        uniforms.stereoWidth = audio.stereoWidth
        uniforms.balance = audio.balance
        uniforms.idle = audio.isIdle ? 1 : 0
        uniforms.tempoConfidence = audio.tempoConfidence
        uniforms.spectrogramCursor = Float(spectrogramRow) / Float(Self.spectrogramRows)
        uniforms.hue = fract(uniforms.time * 0.01 * colorDrift + audio.beatPhase * 0.002 * colorDrift)
        let headroom = edrEnabled
            ? Float(max(1.0, view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1))
            : 1
        uniforms.edrScale = min(2.2, headroom)
        uniforms.palette = (palette.stops[0], palette.stops[1], palette.stops[2], palette.stops[3])
    }

    private func upload(_ audio: AudioFrame) {
        // Interleave left/right into the .rg channels the shaders expect.
        var interleaved = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount * 2)
        for index in 0..<SpectrumAnalyzer.bandCount {
            interleaved[index * 2] = audio.spectrumLeft[index]
            interleaved[index * 2 + 1] = audio.spectrumRight[index]
        }
        interleaved.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            spectrumTexture.replace(region: MTLRegionMake2D(0, 0, SpectrumAnalyzer.bandCount, 1),
                                    mipmapLevel: 0, withBytes: base,
                                    bytesPerRow: SpectrumAnalyzer.bandCount * 2 * MemoryLayout<Float>.size)
        }

        var waves = [Float](repeating: 0, count: SpectrumAnalyzer.waveformCount * 2)
        for index in 0..<SpectrumAnalyzer.waveformCount {
            waves[index * 2] = audio.waveformLeft[index]
            waves[index * 2 + 1] = audio.waveformRight[index]
        }
        waves.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            waveTexture.replace(region: MTLRegionMake2D(0, 0, SpectrumAnalyzer.waveformCount, 1),
                                mipmapLevel: 0, withBytes: base,
                                bytesPerRow: SpectrumAnalyzer.waveformCount * 2 * MemoryLayout<Float>.size)
        }

        // One new row of history per frame; the shader reads backwards from the cursor.
        spectrogramRow = (spectrogramRow + 1) % Self.spectrogramRows
        spectrogramScratch = audio.spectrum
        spectrogramScratch.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            spectrogramTexture.replace(
                region: MTLRegionMake2D(0, spectrogramRow, SpectrumAnalyzer.bandCount, 1),
                mipmapLevel: 0, withBytes: base,
                bytesPerRow: SpectrumAnalyzer.bandCount * MemoryLayout<Float>.size)
        }
    }

    private func reportFrameRate(now: CFTimeInterval) {
        frameCounter += 1
        let elapsed = now - frameRateClock
        if elapsed >= 0.5 {
            onFrameRate?(Double(frameCounter) / elapsed)
            frameCounter = 0
            frameRateClock = now
        }
    }
}

private func fract(_ value: Float) -> Float { value - floor(value) }
private func smoothstep(_ t: Float) -> Float {
    let x = max(0, min(1, t))
    return x * x * (3 - 2 * x)
}
