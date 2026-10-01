import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders the interface offscreen: `MusicVisualizer --snapshot <directory>`.
///
/// The controls are the one part of this app that can't be checked by rendering a
/// shader or measuring a signal, so they get their own way of being looked at
/// without launching a window and taking over the screen.
@MainActor
enum Snapshot {
    static func run(directory: String) -> Never {
        let engine = VisualizerEngine()
        engine.showsTuning = true      // the settings row is the point of the exercise

        write(ContentView(engine: engine), size: CGSize(width: 1320, height: 800),
              to: "\(directory)/ui-controls.png")

        // Every explanation at its real width, so the copy can be proofread in place.
        let explanations: [(String, String)] = [
            ("Sensitivity", HelpText.sensitivity), ("Smoothing", HelpText.smoothing),
            ("Trails", HelpText.trails), ("Color drift", HelpText.colorDrift),
            ("Quality", HelpText.quality), ("HDR", HelpText.hdr),
            ("Idle drift", HelpText.idleDrift), ("Audio source", HelpText.source),
            ("Auto-cycle", HelpText.autoCycle), ("Tempo", HelpText.tempo),
            ("Stereo width", HelpText.stereoWidth)
        ]
        let sheet = VStack(alignment: .leading, spacing: 12) {
            ForEach(explanations, id: \.0) { title, text in
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 11, weight: .semibold))
                    HelpBubble(text: text)
                }
            }
        }
        .padding(24)
        .frame(width: 340, alignment: .topLeading)
        .background(Color.black)

        write(sheet, size: CGSize(width: 340, height: 1500),
              to: "\(directory)/ui-help-text.png")
        print("wrote snapshots to \(directory)")
        exit(0)
    }

    /// Renders through a real offscreen window rather than SwiftUI's `ImageRenderer`.
    ///
    /// `ImageRenderer` draws sliders, pickers and `.ultraThinMaterial` as placeholder
    /// artwork, which makes it useless for reviewing this particular interface —
    /// almost every control it contains is one of those. Hosting the view in an
    /// offscreen window and asking AppKit to cache its display gives the genuine
    /// appearance, materials included.
    private static func write(_ view: some View, size: CGSize, to path: String) {
        let hosting = NSHostingView(rootView: AnyView(view.preferredColorScheme(.dark)))
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        // Off the visible screen, but on-screen enough for AppKit to draw it.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()

        // Let SwiftUI lay out and the material views resolve before capturing.
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("could not allocate a bitmap for \(path)")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        window.orderOut(nil)

        guard let image = representation.cgImage,
              let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("could not encode \(path)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
