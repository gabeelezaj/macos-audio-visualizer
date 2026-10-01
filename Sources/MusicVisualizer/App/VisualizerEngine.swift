import AppKit
import Combine
import CoreAudio
import Foundation

/// Owns the capture chain and every user-facing setting.
@MainActor
final class VisualizerEngine: ObservableObject {
    enum Status: Equatable {
        case idle
        case starting
        case running
        case needsPermission
        case failed(String)
    }

    enum Source: Equatable, Hashable {
        case entireSystem
        case app(AudioObjectID)
    }

    // MARK: - Published state
    @Published private(set) var status: Status = .idle
    @Published private(set) var availableApps: [AudioProcess] = []
    @Published private(set) var isSilent = true
    @Published private(set) var meterLevel: Float = 0
    @Published private(set) var framesPerSecond: Double = 0
    @Published private(set) var bpm: Float = 0
    @Published private(set) var tempoConfidence: Float = 0
    @Published private(set) var stereoWidth: Float = 0
    @Published private(set) var isIdle = false
    /// The tap is running but macOS is handing us digital silence while something
    /// is demonstrably playing — almost always a missing audio-recording grant.
    @Published private(set) var suspectsMissingPermission = false

    @Published var source: Source = .entireSystem { didSet { if source != oldValue { restart() } } }
    @Published var mode: VisualMode = .aurora {
        didSet {
            renderer?.mode = mode
            if trailFollowsMode { trail = mode.defaultTrail; renderer?.trail = trail }
            save()
        }
    }
    @Published var paletteIndex: Int = 0 {
        didSet { renderer?.palette = Palette.all[min(paletteIndex, Palette.all.count - 1)]; save() }
    }
    @Published var sensitivity: Float = 1.0 {
        didSet { analyzer.sensitivity = sensitivity; renderer?.sensitivity = sensitivity; save() }
    }
    @Published var smoothing: Float = 0.5 { didSet { analyzer.smoothing = smoothing; save() } }
    @Published var trail: Float = VisualMode.aurora.defaultTrail {
        didSet { renderer?.trail = trail; save() }
    }
    @Published var colorDrift: Float = 0.35 { didSet { renderer?.colorDrift = colorDrift; save() } }
    @Published var edrEnabled = true { didSet { renderer?.edrEnabled = edrEnabled; save() } }
    @Published var quality: RenderQuality = .automatic { didSet { renderer?.quality = quality; save() } }
    @Published var idleAnimation = true { didSet { analyzer.idleAnimation = idleAnimation; save() } }
    /// Whether the tuning row is expanded. Persisted — someone who opens it once is
    /// usually still tuning next launch.
    @Published var showsTuning = false { didSet { save() } }
    /// Seconds between automatic mode changes; 0 turns it off.
    @Published var autoCycleInterval: Double = 0 {
        didSet { restartAutoCycle(); save() }
    }

    /// When on, changing mode also loads that mode's flattering default trail length.
    var trailFollowsMode = true

    // MARK: - Machinery
    private let tap = SystemAudioTap()
    let analyzer = SpectrumAnalyzer()
    private(set) weak var renderer: Renderer?
    /// Serialises tap start/stop. Creating a process tap is a blocking Core Audio
    /// call that can stall for seconds — notably when another process is holding a
    /// tap open — so it must never run on the main thread, or the window never appears.
    private let controlQueue = DispatchQueue(label: "com.visualizer.tap.control")
    private var appRefreshTimer: Timer?
    private var meterTimer: Timer?
    private var autoCycleTimer: Timer?
    private var lastFrame = AudioFrame.empty(bands: SpectrumAnalyzer.bandCount,
                                             waveform: SpectrumAnalyzer.waveformCount)

    init() {
        load()
        analyzer.sensitivity = sensitivity
        analyzer.smoothing = smoothing
        analyzer.idleAnimation = idleAnimation

        tap.onDefaultDeviceChange = { [weak self] in
            // Speakers → headphones swaps the device out from under the tap.
            Task { @MainActor in self?.restart() }
        }
    }

    func attach(renderer: Renderer) {
        self.renderer = renderer
        renderer.mode = mode
        renderer.palette = Palette.all[min(paletteIndex, Palette.all.count - 1)]
        renderer.sensitivity = sensitivity
        renderer.trail = trail
        renderer.colorDrift = colorDrift
        renderer.edrEnabled = edrEnabled
        renderer.quality = quality
        renderer.frameProvider = { [weak self] deltaTime in
            self?.nextFrame(deltaTime: deltaTime)
                ?? .empty(bands: SpectrumAnalyzer.bandCount, waveform: SpectrumAnalyzer.waveformCount)
        }
        renderer.onFrameRate = { [weak self] rate in
            Task { @MainActor in self?.framesPerSecond = rate }
        }
        renderer.warmUp()
    }

    /// Called from the render loop, once per displayed frame.
    nonisolated func nextFrame(deltaTime: Float) -> AudioFrame {
        MainActor.assumeIsolated {
            lastFrame = analyzer.analyze(ring: tap.ring, deltaTime: deltaTime)
            return lastFrame
        }
    }

    // MARK: - Capture control

    func start() {
        do {
            let target: SystemAudioTap.Target
            switch source {
            case .entireSystem: target = .entireSystem
            case .app(let object): target = .processes([object])
            }
            try tap.start(target: target)
            analyzer.updateSampleRate(tap.sampleRate)
            status = .running
        } catch AudioError.permissionDenied {
            status = .needsPermission
        } catch {
            status = .failed(error.localizedDescription)
        }
        refreshApps()
    }

    func stop() {
        tap.stop()
        appRefreshTimer?.invalidate()
        meterTimer?.invalidate()
        autoCycleTimer?.invalidate()
        status = .idle
    }

    func restart() {
        guard status == .running || status == .idle else { return }
        tap.stop()
        start()
    }

    func retryPermission() {
        status = .idle
        start()
    }

    var isConnecting: Bool { status == .starting }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Switches to a different random visualization on a timer — a "leave it running
    /// at a party" mode. Random rather than sequential so it doesn't feel like a list.
    private func restartAutoCycle() {
        autoCycleTimer?.invalidate()
        autoCycleTimer = nil
        guard autoCycleInterval > 0 else { return }
        autoCycleTimer = Timer.scheduledTimer(withTimeInterval: autoCycleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let others = VisualMode.allCases.filter { $0 != self.mode }
                if let next = others.randomElement() { self.mode = next }
                self.autoCycleCount += 1
                if self.autoCycleCount % 3 == 0 { self.cyclePalette() }
            }
        }
    }

    private var autoCycleCount = 0

    private func startTimers() {
        appRefreshTimer?.invalidate()
        appRefreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshApps() }
        }
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.meterLevel = self.lastFrame.level
                self.isSilent = self.lastFrame.isSilent
                self.isIdle = self.lastFrame.isIdle
                self.stereoWidth = self.lastFrame.stereoWidth
                self.tempoConfidence = self.lastFrame.tempoConfidence
                // Only surface a tempo we actually believe, and hold it steady
                // rather than letting the readout flicker between neighbours.
                let candidate = self.lastFrame.tempoConfidence > 0.6 ? self.lastFrame.bpm : 0
                if abs(candidate - self.bpm) > 0.6 { self.bpm = candidate }
                self.updatePermissionSuspicion()
            }
        }
    }

    /// macOS does not fail tap creation when the grant is missing — it silently
    /// feeds zeros. The only way to tell that apart from "nothing is playing" is
    /// to notice that some other process *is* pushing audio to the speakers.
    private func updatePermissionSuspicion() {
        guard status == .running else {
            suspectsMissingPermission = false
            return
        }
        suspectsMissingPermission = lastFrame.isDigitalSilence && !availableApps.isEmpty
    }

    func dismissPermissionHint() {
        suspectsMissingPermission = false
    }

    private func refreshApps() {
        let apps = AudioProcessLister.processesPlayingAudio()
        if apps != availableApps { availableApps = apps }
        // If the app we were following stopped playing, fall back to the full mix.
        if case .app(let object) = source, !apps.contains(where: { $0.id == object }) {
            source = .entireSystem
        }
    }

    var sourceLabel: String {
        switch source {
        case .entireSystem: return "All system audio"
        case .app(let object): return availableApps.first { $0.id == object }?.name ?? "App"
        }
    }

    // MARK: - Navigation helpers

    func cycleMode(by delta: Int) {
        let all = VisualMode.allCases
        let index = (all.firstIndex(of: mode)! + delta + all.count) % all.count
        mode = all[index]
    }

    func cyclePalette(by delta: Int = 1) {
        paletteIndex = (paletteIndex + delta + Palette.all.count) % Palette.all.count
    }

    /// Flips auto-cycle between off and a sensible default interval.
    func toggleAutoCycle() {
        autoCycleInterval = autoCycleInterval > 0 ? 0 : 30
    }

    func randomize() {
        mode = VisualMode.allCases.randomElement() ?? .aurora
        paletteIndex = Int.random(in: 0..<Palette.all.count)
    }

    // MARK: - Persistence

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(paletteIndex, forKey: "palette")
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(smoothing, forKey: "smoothing")
        defaults.set(trail, forKey: "trail")
        defaults.set(colorDrift, forKey: "colorDrift")
        defaults.set(edrEnabled, forKey: "edr")
        defaults.set(quality.rawValue, forKey: "quality")
        defaults.set(idleAnimation, forKey: "idleAnimation")
        defaults.set(autoCycleInterval, forKey: "autoCycle")
        defaults.set(showsTuning, forKey: "showsTuning")
    }

    private func load() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "mode") != nil else { return }
        mode = VisualMode(rawValue: defaults.integer(forKey: "mode")) ?? .aurora
        paletteIndex = min(defaults.integer(forKey: "palette"), Palette.all.count - 1)
        sensitivity = defaults.float(forKey: "sensitivity")
        smoothing = defaults.float(forKey: "smoothing")
        trail = defaults.float(forKey: "trail")
        colorDrift = defaults.float(forKey: "colorDrift")
        edrEnabled = defaults.bool(forKey: "edr")
        quality = RenderQuality(rawValue: defaults.integer(forKey: "quality")) ?? .automatic
        idleAnimation = defaults.object(forKey: "idleAnimation") as? Bool ?? true
        autoCycleInterval = defaults.double(forKey: "autoCycle")
        showsTuning = defaults.bool(forKey: "showsTuning")
        if sensitivity <= 0 { sensitivity = 1 }
    }
}
