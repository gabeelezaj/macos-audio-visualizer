import Foundation
import simd

enum VisualMode: Int, CaseIterable, Identifiable, Codable {
    case aurora, bars, waveform, radial, tunnel, particles, liquid, grid
    case spectrogram, kaleidoscope, vectorscope

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .aurora: "Aurora"
        case .bars: "Spectrum"
        case .waveform: "Waveform"
        case .radial: "Bloom"
        case .tunnel: "Tunnel"
        case .particles: "Starfield"
        case .liquid: "Liquid"
        case .grid: "Horizon"
        case .spectrogram: "Waterfall"
        case .kaleidoscope: "Kaleidoscope"
        case .vectorscope: "Vectorscope"
        }
    }

    var subtitle: String {
        switch self {
        case .aurora: "Flowing gradient clouds"
        case .bars: "Mirrored frequency bars"
        case .waveform: "Triggered oscilloscope"
        case .radial: "Radial spectrum flower"
        case .tunnel: "Flight through a corridor"
        case .particles: "Beat-reactive motes"
        case .liquid: "Metaball fluid"
        case .grid: "Synthwave horizon"
        case .spectrogram: "Scrolling frequency history"
        case .kaleidoscope: "Mirrored symmetry"
        case .vectorscope: "Stereo field, drawn by the music"
        }
    }

    var symbol: String {
        switch self {
        case .aurora: "aqi.medium"
        case .bars: "chart.bar.fill"
        case .waveform: "waveform"
        case .radial: "circle.hexagongrid.fill"
        case .tunnel: "circle.circle"
        case .particles: "sparkles"
        case .liquid: "drop.fill"
        case .grid: "grid"
        case .spectrogram: "square.grid.3x3.fill"
        case .kaleidoscope: "snowflake"
        case .vectorscope: "circle.dotted"
        }
    }

    var fragmentFunction: String {
        switch self {
        case .aurora: "aurora_fragment"
        case .bars: "bars_fragment"
        case .waveform: "waveform_fragment"
        case .radial: "radial_fragment"
        case .tunnel: "tunnel_fragment"
        case .particles: "particles_fragment"
        case .liquid: "liquid_fragment"
        case .grid: "grid_fragment"
        case .spectrogram: "spectrogram_fragment"
        case .kaleidoscope: "kaleidoscope_fragment"
        case .vectorscope: "vectorscope_fragment"
        }
    }

    /// How much motion blur suits this mode by default, 0...1.
    var defaultTrail: Float {
        switch self {
        case .aurora: 0.15
        case .bars: 0.10
        case .waveform: 0.55
        case .radial: 0.45
        case .tunnel: 0.35
        case .particles: 0.65
        case .liquid: 0.20
        case .grid: 0.30
        case .spectrogram: 0.0
        case .kaleidoscope: 0.35
        case .vectorscope: 0.72
        }
    }

    /// Extra geometry drawn on top of the fullscreen pass.
    ///
    /// The vectorscope plots left against right as a dense cloud of points. Doing
    /// that in a fragment shader would mean hundreds of texture fetches per pixel;
    /// as point primitives it is one vertex per sample.
    var overlay: Overlay {
        self == .vectorscope ? .stereoPoints : .none
    }

    enum Overlay {
        case none
        case stereoPoints
    }
}

struct Palette: Identifiable, Hashable {
    let id: Int
    let name: String
    let stops: [SIMD4<Float>]

    private static func rgb(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xFF) / 255,
              Float((hex >> 8) & 0xFF) / 255,
              Float(hex & 0xFF) / 255,
              1)
    }

    /// Four stops per palette; shaders wrap around from the last back to the first.
    static let all: [Palette] = [
        Palette(id: 0, name: "Sunset",
                stops: [rgb(0x2A0B4E), rgb(0xFF3D81), rgb(0xFF9A3C), rgb(0xFFE9C4)]),
        Palette(id: 1, name: "Neon",
                stops: [rgb(0x050B24), rgb(0x00E5FF), rgb(0x7C4DFF), rgb(0xFF2D9B)]),
        Palette(id: 2, name: "Ocean",
                stops: [rgb(0x001B2E), rgb(0x0FA3B1), rgb(0x7FE3D4), rgb(0xE9FFF9)]),
        Palette(id: 3, name: "Ember",
                stops: [rgb(0x14060A), rgb(0xC1121F), rgb(0xF77F00), rgb(0xFFD166)]),
        Palette(id: 4, name: "Verdant",
                stops: [rgb(0x04150F), rgb(0x1B998B), rgb(0xA3E635), rgb(0xF2FFD6)]),
        Palette(id: 5, name: "Mono",
                stops: [rgb(0x05070A), rgb(0x33414F), rgb(0x9FB2C6), rgb(0xF4F8FF)])
    ]
}
