import Foundation

/// Headless capture check: `MusicVisualizer --diagnose [output-file]`.
///
/// Starts the tap, samples the analyzer for a few seconds and reports what it heard.
/// Useful for confirming permissions and the audio path without opening a window.
@MainActor
enum Diagnostics {
    static func run(outputPath: String?) -> Never {
        var lines: [String] = []
        func emit(_ text: String) {
            print(text)
            // Flush every line: a diagnostic that buffers its output tells you
            // nothing when the thing you are diagnosing hangs.
            fflush(stdout)
            lines.append(text)
            if let outputPath {
                try? lines.joined(separator: "\n").write(toFile: outputPath,
                                                          atomically: true, encoding: .utf8)
            }
        }

        let tap = SystemAudioTap()
        let analyzer = SpectrumAnalyzer()
        emit("Music Visualizer — capture diagnostics")

        do {
            try tap.start(target: .entireSystem)
            analyzer.updateSampleRate(tap.sampleRate)
            emit("tap:        started")
            emit("route:      \(tap.routeDescription)")
            emit("sampleRate: \(Int(tap.sampleRate)) Hz")
        } catch AudioError.permissionDenied {
            emit("tap:        DENIED — grant System Settings ▸ Privacy & Security ▸ Audio Recording")
            finish(lines, outputPath)
        } catch {
            emit("tap:        FAILED — \(error.localizedDescription)")
            finish(lines, outputPath)
        }

        emit("")
        emit("  t     level   bass    mid     treble  width  beats  bpm   peak")
        var beats: Float = 0
        var sawAudio = false
        let start = Date()
        var tick = 0

        let step = 1.0 / 60.0
        var previousTick = Date()
        while Date().timeIntervalSince(start) < 10.0 {
            RunLoop.current.run(until: Date().addingTimeInterval(step))
            // Measure the real interval rather than assuming the nominal one — the
            // analyzer derives tempo from it, so a fixed guess reports a fast BPM.
            let tickTime = Date()
            let elapsed = tickTime.timeIntervalSince(previousTick)
            previousTick = tickTime
            let frame = analyzer.analyze(ring: tap.ring, deltaTime: Float(elapsed))
            beats = frame.beatPhase
            if frame.level > 0.02 { sawAudio = true }
            tick += 1
            if tick % 18 == 0 {
                let peak = frame.spectrum.enumerated().max { $0.element < $1.element }
                let tempo = frame.tempoConfidence > 0.6 ? String(format: "%3.0f", frame.bpm) : "  —"
                emit(String(format: "  %.1fs  %-7.3f %-7.3f %-7.3f %-7.3f %-6.2f %-6.0f %@   b%d",
                            Date().timeIntervalSince(start), frame.level, frame.bass,
                            frame.mid, frame.treble, frame.stereoWidth, beats, tempo,
                            peak?.offset ?? 0))
            }
        }

        emit("")
        emit("io callbacks:    \(tap.callbackCount)")
        emit("frames captured: \(tap.ring.framesWritten)")
        if sawAudio {
            emit("result:     AUDIO DETECTED ✓")
        } else {
            emit("result:     no audio. If something was playing, macOS is feeding this")
            emit("            process silence — grant Audio Recording in System Settings.")
        }
        tap.stop()
        withExtendedLifetime(tap) {}
        finish(lines, outputPath)
    }

    private static func finish(_ lines: [String], _ path: String?) -> Never {
        if let path {
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        exit(0)
    }
}
