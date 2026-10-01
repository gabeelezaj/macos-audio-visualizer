import Accelerate
import Foundation

/// One frame of analysis, sized and scaled for direct consumption by the shaders.
struct AudioFrame {
    var spectrum: [Float]        // mono, `bandCount` log-spaced bands, 0...1
    var spectrumLeft: [Float]
    var spectrumRight: [Float]
    var waveformLeft: [Float]    // `waveformCount` samples, -1...1, zero-crossing aligned
    var waveformRight: [Float]
    var level: Float             // smoothed loudness, 0...1
    var bass: Float
    var mid: Float
    var treble: Float
    var beat: Float              // 1 on the transient, decaying afterwards
    var beatPhase: Float         // increments by 1 per detected beat
    var tempoPhase: Float        // continuous, advances one per beat at the tracked tempo
    var bpm: Float               // 0 until a tempo is established
    var tempoConfidence: Float   // 0...1
    var stereoWidth: Float       // 0 = mono, 1+ = wide
    var balance: Float           // -1 hard left ... +1 hard right
    var isSilent: Bool
    /// Bit-exact zero for several seconds — the signature of a missing capture grant.
    var isDigitalSilence: Bool
    var isIdle: Bool             // silence, with the idle animation driving the visuals

    static func empty(bands: Int, waveform: Int) -> AudioFrame {
        AudioFrame(spectrum: .init(repeating: 0, count: bands),
                   spectrumLeft: .init(repeating: 0, count: bands),
                   spectrumRight: .init(repeating: 0, count: bands),
                   waveformLeft: .init(repeating: 0, count: waveform),
                   waveformRight: .init(repeating: 0, count: waveform),
                   level: 0, bass: 0, mid: 0, treble: 0, beat: 0, beatPhase: 0,
                   tempoPhase: 0, bpm: 0, tempoConfidence: 0,
                   stereoWidth: 0, balance: 0,
                   isSilent: true, isDigitalSilence: false, isIdle: false)
    }
}

/// Windowing, FFT scratch and magnitudes for a single channel.
private final class ChannelProcessor {
    let samples: UnsafeMutablePointer<Float>
    private var windowed: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private(set) var magnitudes: [Float]
    private let size: Int
    private let halfSize: Int

    init(size: Int) {
        self.size = size
        halfSize = size / 2
        samples = .allocate(capacity: size)
        samples.initialize(repeating: 0, count: size)
        windowed = .init(repeating: 0, count: size)
        realPart = .init(repeating: 0, count: halfSize)
        imagPart = .init(repeating: 0, count: halfSize)
        magnitudes = .init(repeating: 0, count: halfSize)
    }

    deinit {
        samples.deinitialize(count: size)
        samples.deallocate()
    }

    func transform(window: [Float], fft: vDSP.FFT<DSPSplitComplex>) {
        let input = UnsafeBufferPointer(start: samples, count: size)
        window.withUnsafeBufferPointer { windowBuffer in
            windowed.withUnsafeMutableBufferPointer { output in
                vDSP_vmul(input.baseAddress!, 1, windowBuffer.baseAddress!, 1,
                          output.baseAddress!, 1, vDSP_Length(size))
            }
        }
        windowed.withUnsafeBufferPointer { input in
            realPart.withUnsafeMutableBufferPointer { real in
                imagPart.withUnsafeMutableBufferPointer { imaginary in
                    var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfSize))
                    }
                    fft.forward(input: split, output: &split)
                    magnitudes.withUnsafeMutableBufferPointer { output in
                        vDSP_zvabs(&split, 1, output.baseAddress!, 1, vDSP_Length(halfSize))
                    }
                }
            }
        }
        vDSP.multiply(1 / Float(size), magnitudes, result: &magnitudes)
    }
}

/// Turns raw stereo samples into the handful of numbers a visualizer actually wants.
///
/// The chain is: Hann window → real FFT per channel → magnitude → per-octave pink
/// tilt → log-spaced bands → auto gain → asymmetric (fast-attack, slow-release)
/// smoothing. Auto gain is what keeps a quiet acoustic track as lively as a loud one.
final class SpectrumAnalyzer {
    static let bandCount = 128
    static let waveformCount = 512

    private let fftSize = 4096
    private let halfSize: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let leftChannel: ChannelProcessor
    private let rightChannel: ChannelProcessor

    private var sampleRate: Float = 48_000
    private var window: [Float]
    private var monoMagnitudes: [Float]
    private var monoSamples: [Float]

    private var smoothedBands: [Float]
    private var smoothedLeft: [Float]
    private var smoothedRight: [Float]
    private var displayBands: [Float]
    private var displayLeft: [Float]
    private var displayRight: [Float]
    private var bandRanges: [(lower: Int, upper: Int, tilt: Float)] = []
    private var waveformLeft: [Float]
    private var waveformRight: [Float]

    // Auto gain
    private var gain: Float = 1
    private var peakEnvelope: Float = 0.2

    // Band envelopes
    private var bassEnv: Float = 0
    private var midEnv: Float = 0
    private var trebleEnv: Float = 0
    private var levelEnv: Float = 0
    private var widthEnv: Float = 0
    private var balanceEnv: Float = 0

    // Onset detection
    private var previousMagnitudes: [Float]
    private var fluxReference: Float = 0
    private var fluxMean: Float = 0
    private var fluxVariance: Float = 0
    private var analysisTime: Float = 0
    private var timeSinceBeat: Float = 9
    private var beatPulse: Float = 0
    private var beatPhase: Float = 0
    private var silentTime: Float = 0
    private var digitalSilenceTime: Float = 0

    // Tempo tracking
    private var beatIntervals: [Float] = []
    private var beatPeriod: Float = 0
    private var tempoPhase: Float = 0
    private var tempoConfidence: Float = 0

    private var idleTime: Float = 0

    /// 0.5 (tame) ... 2.0 (hot). Scales everything the shaders react to.
    var sensitivity: Float = 1.0
    /// 0 (instant, twitchy) ... 1 (glassy smooth).
    var smoothing: Float = 0.5
    /// Keeps the visuals gently moving when nothing is playing.
    var idleAnimation = true

    init(sampleRate: Double = 48_000) {
        halfSize = fftSize / 2
        guard let fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("Could not create FFT setup")
        }
        self.fft = fft
        leftChannel = ChannelProcessor(size: fftSize)
        rightChannel = ChannelProcessor(size: fftSize)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: fftSize, isHalfWindow: false)
        monoMagnitudes = .init(repeating: 0, count: halfSize)
        monoSamples = .init(repeating: 0, count: fftSize)
        previousMagnitudes = .init(repeating: 0, count: halfSize)
        smoothedBands = .init(repeating: 0, count: Self.bandCount)
        smoothedLeft = .init(repeating: 0, count: Self.bandCount)
        smoothedRight = .init(repeating: 0, count: Self.bandCount)
        displayBands = .init(repeating: 0, count: Self.bandCount)
        displayLeft = .init(repeating: 0, count: Self.bandCount)
        displayRight = .init(repeating: 0, count: Self.bandCount)
        waveformLeft = .init(repeating: 0, count: Self.waveformCount)
        waveformRight = .init(repeating: 0, count: Self.waveformCount)
        updateSampleRate(sampleRate)
    }

    func updateSampleRate(_ rate: Double) {
        let newRate = Float(max(8_000, rate))
        guard newRate != sampleRate || bandRanges.isEmpty else { return }
        sampleRate = newRate
        buildBandRanges()
    }

    /// Splits 25 Hz – 18 kHz into perceptually even (log-spaced) buckets and
    /// precomputes each bucket's pink-noise tilt so highs aren't perpetually dim.
    private func buildBandRanges() {
        let minHz: Float = 25
        let maxHz: Float = min(18_000, sampleRate * 0.45)
        let binWidth = sampleRate / Float(fftSize)
        bandRanges = (0..<Self.bandCount).map { index in
            let t0 = Float(index) / Float(Self.bandCount)
            let t1 = Float(index + 1) / Float(Self.bandCount)
            let f0 = minHz * pow(maxHz / minHz, t0)
            let f1 = minHz * pow(maxHz / minHz, t1)
            let lower = max(1, Int(f0 / binWidth))
            let upper = max(lower + 1, min(halfSize - 1, Int(f1 / binWidth) + 1))
            let centre = sqrt(f0 * f1)
            let tilt = min(20, max(-6, 3.2 * log2(centre / 180)))   // dB
            return (lower, upper, tilt)
        }
    }

    private func binRange(_ lowHz: Float, _ highHz: Float) -> Range<Int> {
        let binWidth = sampleRate / Float(fftSize)
        let lower = max(1, Int(lowHz / binWidth))
        let upper = max(lower + 1, min(halfSize, Int(highHz / binWidth)))
        return lower..<upper
    }

    // MARK: - Per-frame analysis

    /// - Parameter deltaTime: seconds since the previous call. Every envelope below
    ///   is expressed as a time constant, so the visualization behaves identically
    ///   at 60 Hz and on a 120 Hz ProMotion display.
    func analyze(ring: AudioRingBuffer, deltaTime: Float) -> AudioFrame {
        let dt = min(0.1, max(1.0 / 240, deltaTime))
        analysisTime += dt

        ring.readLatest(left: leftChannel.samples, right: rightChannel.samples, count: fftSize)

        let leftBuffer = UnsafeBufferPointer(start: leftChannel.samples, count: fftSize)
        let rightBuffer = UnsafeBufferPointer(start: rightChannel.samples, count: fftSize)

        // Mid/side tells us the stereo image; mid is also what we analyse for level.
        var midRMS: Float = 0
        var sideRMS: Float = 0
        var leftRMS: Float = 0
        var rightRMS: Float = 0
        for i in 0..<fftSize {
            let l = leftBuffer[i]
            let r = rightBuffer[i]
            let mid = (l + r) * 0.5
            let side = (l - r) * 0.5
            monoSamples[i] = mid
            midRMS += mid * mid
            sideRMS += side * side
            leftRMS += l * l
            rightRMS += r * r
        }
        let inverseCount = 1 / Float(fftSize)
        midRMS = sqrt(midRMS * inverseCount)
        sideRMS = sqrt(sideRMS * inverseCount)
        leftRMS = sqrt(leftRMS * inverseCount)
        rightRMS = sqrt(rightRMS * inverseCount)

        let rms = midRMS
        silentTime = rms < 2e-5 ? silentTime + dt : 0
        let isSilent = silentTime > 1.5

        let peakSample = vDSP.maximumMagnitude(monoSamples)
        digitalSilenceTime = peakSample == 0 ? digitalSilenceTime + dt : 0

        leftChannel.transform(window: window, fft: fft)
        rightChannel.transform(window: window, fft: fft)
        for bin in 0..<halfSize {
            monoMagnitudes[bin] = (leftChannel.magnitudes[bin] + rightChannel.magnitudes[bin]) * 0.5
        }

        // --- Display bands ---------------------------------------------------
        let attack = coefficient(tau: 0.010 + 0.055 * smoothing, dt: dt)
        let release = coefficient(tau: 0.055 + 0.40 * smoothing, dt: dt)
        var loudestBand: Float = 0

        for (index, range) in bandRanges.enumerated() {
            let mono = bandValue(monoMagnitudes, range)
            loudestBand = max(loudestBand, mono)
            smoothedBands[index] = follow(smoothedBands[index], min(1.4, mono * gain * sensitivity),
                                          attack: attack, release: release)
            smoothedLeft[index] = follow(smoothedLeft[index],
                                         min(1.4, bandValue(leftChannel.magnitudes, range) * gain * sensitivity),
                                         attack: attack, release: release)
            smoothedRight[index] = follow(smoothedRight[index],
                                          min(1.4, bandValue(rightChannel.magnitudes, range) * gain * sensitivity),
                                          attack: attack, release: release)
        }

        // --- Auto gain -------------------------------------------------------
        // Chase the loudest band upward quickly, drift back down over ~2.5 s so
        // quiet passages open up without the whole scene pumping.
        peakEnvelope = loudestBand > peakEnvelope
            ? peakEnvelope + (loudestBand - peakEnvelope) * coefficient(tau: 0.09, dt: dt)
            : peakEnvelope + (loudestBand - peakEnvelope) * coefficient(tau: 2.5, dt: dt)
        let targetGain = isSilent ? 1 : min(4.5, max(0.7, 0.92 / max(peakEnvelope, 0.16)))
        gain += (targetGain - gain) * coefficient(tau: 0.5, dt: dt)

        // --- Bands -----------------------------------------------------------
        let bassRaw = energy(in: binRange(25, 160), floor: -70, ceiling: -14)
        let midRaw = energy(in: binRange(160, 2_000), floor: -74, ceiling: -18)
        let trebleRaw = energy(in: binRange(2_000, 12_000), floor: -84, ceiling: -26)
        // Typical music sits near -18 dBFS RMS; this puts that around 0.6 and
        // leaves genuine peaks room to reach 1.0 instead of pinning there.
        let levelRaw = min(1.2, sqrt(rms * 2.4))

        bassEnv = envelope(bassEnv, bassRaw * gain * sensitivity, attackTau: 0.018, releaseTau: 0.13, dt: dt)
        midEnv = envelope(midEnv, midRaw * gain * sensitivity, attackTau: 0.022, releaseTau: 0.11, dt: dt)
        trebleEnv = envelope(trebleEnv, trebleRaw * gain * sensitivity, attackTau: 0.015, releaseTau: 0.075, dt: dt)
        levelEnv = envelope(levelEnv, levelRaw * gain * sensitivity, attackTau: 0.030, releaseTau: 0.20, dt: dt)

        // --- Stereo image ----------------------------------------------------
        let widthRaw = min(1.5, sideRMS / (midRMS + 1e-6))
        let balanceRaw = (rightRMS - leftRMS) / (rightRMS + leftRMS + 1e-6)
        widthEnv += (widthRaw - widthEnv) * coefficient(tau: 0.35, dt: dt)
        balanceEnv += (balanceRaw - balanceEnv) * coefficient(tau: 0.35, dt: dt)

        let onset = spectralFlux(in: binRange(25, 220), dt: dt)
        detectBeat(onset: onset, isSilent: isSilent, dt: dt)
        trackTempo(dt: dt)
        blurBands()
        buildWaveform(dt: dt, left: leftBuffer, right: rightBuffer)

        var frame = AudioFrame(spectrum: displayBands,
                               spectrumLeft: displayLeft,
                               spectrumRight: displayRight,
                               waveformLeft: waveformLeft,
                               waveformRight: waveformRight,
                               level: min(1.3, levelEnv),
                               bass: min(1.3, bassEnv),
                               mid: min(1.3, midEnv),
                               treble: min(1.3, trebleEnv),
                               beat: beatPulse,
                               beatPhase: beatPhase,
                               tempoPhase: tempoPhase,
                               bpm: beatPeriod > 0 ? 60 / beatPeriod : 0,
                               tempoConfidence: tempoConfidence,
                               stereoWidth: max(0, widthEnv),
                               balance: max(-1, min(1, balanceEnv)),
                               isSilent: isSilent,
                               isDigitalSilence: digitalSilenceTime > 2.5,
                               isIdle: false)

        if isSilent && idleAnimation {
            applyIdleAnimation(to: &frame, dt: dt)
        } else {
            idleTime = 0
        }
        return frame
    }

    private func bandValue(_ magnitudes: [Float], _ range: (lower: Int, upper: Int, tilt: Float)) -> Float {
        var peak: Float = 0
        var sum: Float = 0
        for bin in range.lower..<range.upper {
            let value = magnitudes[bin]
            peak = max(peak, value)
            sum += value
        }
        let count = Float(range.upper - range.lower)
        // Peak keeps transients punchy, mean keeps the shape stable.
        let blended = peak * 0.7 + (sum / count) * 0.3
        let decibels = 20 * log10(blended + 1e-9) + range.tilt
        return min(1.6, max(0, (decibels + 78) / 66))          // -78 dBFS ... -12 dBFS
    }

    private func follow(_ current: Float, _ target: Float, attack: Float, release: Float) -> Float {
        target > current ? current + (target - current) * attack
                         : current + (target - current) * release
    }

    private func energy(in range: Range<Int>, floor: Float, ceiling: Float) -> Float {
        guard !range.isEmpty else { return 0 }
        var sum: Float = 0
        for bin in range { sum += monoMagnitudes[bin] * monoMagnitudes[bin] }
        let mean = sqrt(sum / Float(range.count))
        let decibels = 20 * log10(mean + 1e-9)
        return min(1.5, max(0, (decibels - floor) / (ceiling - floor)))
    }

    /// Per-step weight for an exponential filter with time constant `tau`.
    private func coefficient(tau: Float, dt: Float) -> Float {
        1 - exp(-dt / max(tau, 1e-4))
    }

    private func envelope(_ current: Float, _ target: Float,
                          attackTau: Float, releaseTau: Float, dt: Float) -> Float {
        let clamped = max(0, target)
        let tau = clamped > current ? attackTau : releaseTau
        return current + (clamped - current) * coefficient(tau: tau, dt: dt)
    }

    /// Blurs neighbouring bands together.
    ///
    /// Bin-to-bin jitter is inherent to an FFT, and any shader that maps frequency
    /// across space turns that jitter into a hard zigzag — a spiky flower edge, a
    /// combed horizon. Smoothing once here fixes every visualization at the source.
    private func blurBands() {
        blur(smoothedBands, into: &displayBands)
        blur(smoothedLeft, into: &displayLeft)
        blur(smoothedRight, into: &displayRight)
    }

    private func blur(_ source: [Float], into destination: inout [Float]) {
        let kernel: [Float] = [0.08, 0.22, 0.40, 0.22, 0.08]
        let count = source.count
        for index in 0..<count {
            var sum: Float = 0
            for (offset, weight) in kernel.enumerated() {
                sum += source[min(count - 1, max(0, index + offset - 2))] * weight
            }
            destination[index] = sum
        }
    }

    // MARK: - Onset and tempo

    /// Rise in low-frequency content since the last frame, relative to how loud
    /// that region has been running.
    ///
    /// Plain energy thresholding fails on material with a sustained bass note: the
    /// note keeps the average high, so the kick on top of it barely stands out.
    /// Flux only counts bins that *grew*, which is what an onset actually is, and
    /// normalising by the running level makes the threshold volume-independent.
    private func spectralFlux(in range: Range<Int>, dt: Float) -> Float {
        var rise: Float = 0
        var total: Float = 0
        for bin in range {
            let magnitude = monoMagnitudes[bin]
            rise += max(0, magnitude - previousMagnitudes[bin])
            total += magnitude
            previousMagnitudes[bin] = magnitude
        }
        fluxReference += (total - fluxReference) * coefficient(tau: 1.5, dt: dt)
        // How much new material enters the analysis window scales with the hop, so
        // raw flux shrinks as the frame rate climbs. Normalise to a 60 Hz hop to
        // keep one threshold valid on both 60 Hz and 120 Hz displays.
        return rise / (fluxReference + 1e-7) * ((1.0 / 60.0) / dt)
    }

    private func detectBeat(onset: Float, isSilent: Bool, dt: Float) {
        let threshold = fluxMean * (1.30 + min(0.9, fluxVariance * 9)) + 0.02

        timeSinceBeat += dt
        // Hold off until the running statistics mean something, or the first frames
        // (mean still at zero) all read as onsets.
        let settled = analysisTime > 0.5
        if settled, !isSilent, onset > threshold, onset > 0.05, timeSinceBeat > 0.12 {
            recordBeatInterval(timeSinceBeat)
            beatPulse = 1
            beatPhase += 1
            timeSinceBeat = 0
        } else {
            beatPulse *= exp(-dt / 0.10)
        }

        // Update after the test so a transient never contributes to the threshold
        // it is being measured against.
        let weight = coefficient(tau: 0.9, dt: dt)
        fluxMean += (onset - fluxMean) * weight
        let deviation = onset - fluxMean
        fluxVariance += (deviation * deviation - fluxVariance) * weight
    }

    /// Folds an inter-onset interval into the 60–190 BPM range before recording it.
    ///
    /// Detected onsets land on eighths as readily as quarters, so raw intervals
    /// cluster around the true period *and* its halves and doubles. Folding by
    /// octaves puts them all in one cluster that a median can resolve.
    private func recordBeatInterval(_ interval: Float) {
        guard interval > 0.15, interval < 4 else { return }
        var folded = interval
        while folded < 0.315 { folded *= 2 }      // faster than 190 BPM
        while folded > 1.0 { folded /= 2 }        // slower than 60 BPM
        beatIntervals.append(folded)
        if beatIntervals.count > 24 { beatIntervals.removeFirst() }
    }

    private func trackTempo(dt: Float) {
        if beatIntervals.count >= 6 {
            let sorted = beatIntervals.sorted()
            let median = sorted[sorted.count / 2]
            // Confidence is simply how many intervals agree with the median.
            let agreeing = beatIntervals.filter { abs($0 - median) < median * 0.14 }.count
            let confidence = Float(agreeing) / Float(beatIntervals.count)
            tempoConfidence += (confidence - tempoConfidence) * coefficient(tau: 1.0, dt: dt)
            if confidence > 0.5 {
                beatPeriod = beatPeriod > 0
                    ? beatPeriod + (median - beatPeriod) * coefficient(tau: 1.5, dt: dt)
                    : median
            }
        } else {
            tempoConfidence += (0 - tempoConfidence) * coefficient(tau: 1.0, dt: dt)
        }

        guard beatPeriod > 0 else { return }
        tempoPhase += dt / beatPeriod
        // Nudge the phase toward the nearest whole beat when one actually lands, so
        // shaders get a continuous tempo-locked value that never jumps.
        if beatPulse > 0.98 {
            let nearest = (tempoPhase).rounded()
            tempoPhase += (nearest - tempoPhase) * 0.3
        }
    }

    // MARK: - Waveform

    /// Aligns the scope to a rising zero crossing so the trace stops sliding sideways.
    private func buildWaveform(dt: Float,
                               left: UnsafeBufferPointer<Float>,
                               right: UnsafeBufferPointer<Float>) {
        let span = Self.waveformCount * 2
        var origin = fftSize - span - 256
        var searchIndex = origin
        let limit = origin + 256
        while searchIndex < limit - 1 {
            if monoSamples[searchIndex] <= 0, monoSamples[searchIndex + 1] > 0 { origin = searchIndex; break }
            searchIndex += 1
        }
        origin = max(0, min(fftSize - span, origin))

        var peak: Float = 1e-4
        for index in 0..<span { peak = max(peak, abs(monoSamples[origin + index])) }
        let scale = min(6, 0.85 / peak) * min(1.4, 0.35 + levelEnv)
        let smoothingWeight = coefficient(tau: 0.006 + 0.030 * smoothing, dt: dt)

        for index in 0..<Self.waveformCount {
            let offset = origin + index * 2
            let leftValue = (left[offset] + left[offset + 1]) * 0.5 * scale
            let rightValue = (right[offset] + right[offset + 1]) * 0.5 * scale
            waveformLeft[index] += (max(-1, min(1, leftValue)) - waveformLeft[index]) * smoothingWeight
            waveformRight[index] += (max(-1, min(1, rightValue)) - waveformRight[index]) * smoothingWeight
        }
    }

    // MARK: - Idle

    /// Keeps the scene breathing when nothing is playing.
    ///
    /// A frozen visualizer looks broken; a slowly drifting one looks like it is
    /// waiting. The values stay well below what real audio produces so there is no
    /// mistaking one for the other.
    private func applyIdleAnimation(to frame: inout AudioFrame, dt: Float) {
        idleTime += dt
        let t = idleTime
        let breathe = 0.5 + 0.5 * sin(t * 0.55)
        let slow = 0.5 + 0.5 * sin(t * 0.23 + 1.1)

        frame.level = 0.10 + 0.12 * breathe
        frame.bass = 0.08 + 0.14 * slow
        frame.mid = 0.07 + 0.10 * (0.5 + 0.5 * sin(t * 0.41 + 2.3))
        frame.treble = 0.04 + 0.06 * (0.5 + 0.5 * sin(t * 0.67 + 4.1))
        frame.beat = max(0, 0.35 * sin(t * 0.9)) * 0.5
        frame.beatPhase = t * 0.35
        frame.tempoPhase = t * 0.35
        frame.stereoWidth = 0.3 + 0.2 * slow
        frame.isIdle = true

        for index in 0..<frame.spectrum.count {
            let position = Float(index) / Float(frame.spectrum.count)
            let shape = exp(-position * 2.6) * (0.55 + 0.45 * sin(t * 0.7 + position * 9))
            let value = max(0, 0.26 * shape * (0.6 + 0.4 * breathe))
            frame.spectrum[index] = value
            frame.spectrumLeft[index] = value * (0.85 + 0.15 * sin(t * 0.5))
            frame.spectrumRight[index] = value * (0.85 + 0.15 * cos(t * 0.5))
        }
        for index in 0..<frame.waveformLeft.count {
            let position = Float(index) / Float(frame.waveformLeft.count)
            let value = 0.16 * sin(position * .pi * 4 + t * 1.3) * (0.5 + 0.5 * breathe)
            frame.waveformLeft[index] = value
            frame.waveformRight[index] = value * 0.85 + 0.05 * sin(position * .pi * 6 - t)
        }
    }
}
