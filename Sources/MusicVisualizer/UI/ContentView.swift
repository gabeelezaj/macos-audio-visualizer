import SwiftUI

struct ContentView: View {
    @ObservedObject var engine: VisualizerEngine
    @StateObject private var host = RenderHost()
    @State private var controlsVisible = true
    @State private var hideWorkItem: DispatchWorkItem?
    /// Number of help markers currently hovered. Reading a tooltip involves holding
    /// the pointer still, which is exactly what the auto-hide timer waits for.
    @State private var helpHovers = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = host.renderer {
                MetalView(renderer: renderer)
                    .ignoresSafeArea()
                    .onAppear { engine.attach(renderer: renderer) }
            } else if let error = host.error {
                FailureView(title: "Can't start the renderer", message: error)
            }

            overlay
        }
        .background(WindowAccessor())
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onAppear { revealControls() }
        .environment(\.onHelpHover) { hovering in
            helpHovers = max(0, helpHovers + (hovering ? 1 : -1))
            if helpHovers > 0 {
                hideWorkItem?.cancel()
                controlsVisible = true
            } else {
                revealControls()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Overlay

    @ViewBuilder
    private var overlay: some View {
        VStack(spacing: 0) {
            TopBar(engine: engine)
                .padding(.horizontal, 18)
                .padding(.top, 30)          // clear of the traffic lights
            Spacer(minLength: 0)

            if engine.status == .starting {
                ConnectingHint()
                Spacer(minLength: 0)
            } else if engine.status == .needsPermission {
                PermissionCard(engine: engine)
                Spacer(minLength: 0)
            } else if case .failed(let message) = engine.status {
                FailureView(title: "Audio capture failed", message: message)
                Spacer(minLength: 0)
            } else if engine.suspectsMissingPermission {
                SilentTapHint(engine: engine)
                Spacer(minLength: 0)
            } else if engine.isSilent {
                SilenceHint()
                Spacer(minLength: 0)
            }

            ControlDock(engine: engine)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
        }
        .opacity(controlsVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.35), value: controlsVisible)
        .allowsHitTesting(controlsVisible)
    }

    private func revealControls() {
        if !controlsVisible { controlsVisible = true }
        hideWorkItem?.cancel()
        guard helpHovers == 0 else { return }
        let item = DispatchWorkItem {
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: item)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var engine: VisualizerEngine

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.mode.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(engine.mode.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if engine.bpm > 0 {
                HStack(spacing: 3) {
                    TempoBadge(bpm: engine.bpm)
                    HelpTip(text: HelpText.tempo, edge: .bottom)
                }
                .transition(.opacity)
            }
            HStack(spacing: 3) {
                StereoBadge(width: engine.stereoWidth)
                HelpTip(text: HelpText.stereoWidth, edge: .bottom)
            }
            LevelMeter(level: engine.meterLevel)
            HStack(spacing: 3) {
                sourceMenu
                HelpTip(text: HelpText.source, edge: .bottom)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.bpm > 0)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private var sourceMenu: some View {
        Menu {
            Button {
                engine.source = .entireSystem
            } label: {
                Label("All system audio", systemImage: "speaker.wave.3.fill")
            }
            if !engine.availableApps.isEmpty {
                Divider()
                Section("Only this app") {
                    ForEach(engine.availableApps) { app in
                        Button(app.name) { engine.source = .app(app.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: engine.status == .running ? "waveform.circle.fill" : "exclamationmark.circle")
                Text(engine.sourceLabel).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct TempoBadge: View {
    let bpm: Float

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "metronome.fill").font(.system(size: 9))
            Text("\(Int(bpm.rounded()))")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("BPM").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.08), in: Capsule())
        .help("Detected tempo")
    }
}

/// Compact stereo-width readout: the dot spreads apart as the image widens.
private struct StereoBadge: View {
    let width: Float

    var body: some View {
        let spread = CGFloat(min(1, width)) * 7
        HStack(spacing: 0) {
            Circle().fill(.white.opacity(0.75)).frame(width: 4, height: 4)
                .offset(x: -spread)
            Circle().fill(.white.opacity(0.75)).frame(width: 4, height: 4)
                .offset(x: spread)
        }
        .frame(width: 26, height: 14)
        .animation(.easeOut(duration: 0.2), value: width)
        .help("Stereo width")
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<14, id: \.self) { index in
                let threshold = Float(index) / 14
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > threshold ? Color.white.opacity(0.85) : Color.white.opacity(0.13))
                    .frame(width: 3, height: 4 + CGFloat(index) * 0.9)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .frame(height: 18)
    }
}

// MARK: - Control dock

private struct ControlDock: View {
    @ObservedObject var engine: VisualizerEngine

    var body: some View {
        VStack(spacing: 10) {
            if engine.showsTuning {
                tuning
                Divider().opacity(0.2)
            }

            // Eleven modes don't fit a narrow window; let the row scroll.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(VisualMode.allCases) { mode in
                        ModeChip(mode: mode, isSelected: engine.mode == mode) { engine.mode = mode }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 44)

            HStack(spacing: 8) {
                ForEach(Palette.all) { palette in
                    PaletteSwatch(palette: palette, isSelected: engine.paletteIndex == palette.id) {
                        engine.paletteIndex = palette.id
                    }
                }

                Divider().frame(height: 24).opacity(0.25)

                IconButton(symbol: "dice", help: "Shuffle (R)") { engine.randomize() }
                HStack(spacing: 2) {
                    autoCycleMenu
                    HelpTip(text: HelpText.autoCycle)
                }
                IconButton(symbol: "slider.horizontal.3", help: "Tuning", isActive: engine.showsTuning) {
                    withAnimation(.easeInOut(duration: 0.2)) { engine.showsTuning.toggle() }
                }
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Full screen (F)") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }

                Spacer(minLength: 0)

                if engine.isIdle {
                    Text("waiting for audio")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        .frame(maxWidth: 1000)
    }

    private var autoCycleMenu: some View {
        Menu {
            Picker("Auto-cycle", selection: $engine.autoCycleInterval) {
                Text("Off").tag(0.0)
                Text("Every 15 seconds").tag(15.0)
                Text("Every 30 seconds").tag(30.0)
                Text("Every minute").tag(60.0)
                Text("Every 2 minutes").tag(120.0)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: engine.autoCycleInterval > 0 ? "shuffle.circle.fill" : "shuffle.circle")
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 38)
        .background(engine.autoCycleInterval > 0 ? Color.white.opacity(0.16) : Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help("Auto-cycle visualizations")
    }

    private var tuning: some View {
        HStack(spacing: 16) {
            LabeledSlider(title: "Sensitivity", value: $engine.sensitivity,
                          range: 0.4...2.2, help: HelpText.sensitivity)
            LabeledSlider(title: "Smoothing", value: $engine.smoothing,
                          range: 0...1, help: HelpText.smoothing)
            LabeledSlider(title: "Trails", value: $engine.trail,
                          range: 0...1, help: HelpText.trails)
            LabeledSlider(title: "Color drift", value: $engine.colorDrift,
                          range: 0...1, help: HelpText.colorDrift)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text("Quality").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    HelpTip(text: HelpText.quality)
                }
                Picker("", selection: $engine.quality) {
                    ForEach(RenderQuality.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 104)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Toggle("HDR", isOn: $engine.edrEnabled)
                    HelpTip(text: HelpText.hdr)
                }
                HStack(spacing: 3) {
                    Toggle("Idle drift", isOn: $engine.idleAnimation)
                    HelpTip(text: HelpText.idleDrift)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .font(.system(size: 10, weight: .medium))
            .fixedSize()

            Text("\(Int(engine.framesPerSecond.rounded())) fps")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

private struct ModeChip: View {
    let mode: VisualMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: mode.symbol).font(.system(size: 14, weight: .medium))
                Text(mode.title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .frame(width: 68, height: 40)
            .background(isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.35 : 0.06)))
        }
        .buttonStyle(.plain)
        .help("\(mode.title) — \(mode.subtitle)")
    }
}

private struct PaletteSwatch: View {
    let palette: Palette
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: palette.stops.map {
                    Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z))
                }, startPoint: .leading, endPoint: .trailing))
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(isSelected ? 0.9 : 0.12), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(palette.name)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 34, height: 38)
                .background(isActive ? Color.white.opacity(0.16) : Color.white.opacity(0.03),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                HelpTip(text: help)
            }
            Slider(value: $value, in: range)
                .controlSize(.mini)
                .frame(width: 96)
        }
    }
}

// MARK: - Status views

/// Creating a process tap can stall for a moment, so say so rather than showing
/// an empty screen that looks broken.
private struct ConnectingHint: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Connecting to system audio…").font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 12)
    }
}

private struct SilenceHint: View {
    var body: some View {
        Label("Play something — the visualizer follows your speakers", systemImage: "music.note")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(radius: 12)
    }
}

/// Shown when the tap is alive but only ever delivers zeros while other apps play.
private struct SilentTapHint: View {
    @ObservedObject var engine: VisualizerEngine

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "speaker.slash.circle").font(.system(size: 30, weight: .light))
            Text("Something is playing, but the tap is silent")
                .font(.system(size: 14, weight: .semibold))
            Text("macOS hands out silence instead of an error when audio recording\nhasn't been allowed. Enable Music Visualizer under Privacy & Security ▸ Audio Recording.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open Privacy Settings") { engine.openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
                Button("Restart Capture") { engine.restart() }
                Button("Dismiss") { engine.dismissPermissionHint() }
            }
        }
        .padding(24)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 26)
    }
}

private struct PermissionCard: View {
    @ObservedObject var engine: VisualizerEngine

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 38, weight: .light))
            Text("Let the visualizer hear your Mac")
                .font(.system(size: 17, weight: .semibold))
            Text("macOS needs permission to read your system audio output.\nEnable Music Visualizer under Privacy & Security → Audio Recording, then try again.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open Privacy Settings") { engine.openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { engine.retryPermission() }
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 30)
    }
}

private struct FailureView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30, weight: .light))
            Text(title).font(.system(size: 15, weight: .semibold))
            ScrollView {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
        }
        .padding(24)
        .frame(maxWidth: 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 24)
    }
}

/// Strips the window chrome so the visualization runs edge to edge.
private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
