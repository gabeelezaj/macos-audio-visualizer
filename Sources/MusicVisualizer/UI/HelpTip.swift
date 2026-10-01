import SwiftUI

/// A dimmed question mark that reveals an explanation on hover.
///
/// The native `.help()` tooltip is set as well, for VoiceOver and for anyone who
/// hovers the control itself rather than the marker — but the visible glyph is the
/// point: a setting whose tooltip nobody knows to look for may as well be undocumented.
struct HelpTip: View {
    let text: String
    /// Which side of the marker the bubble opens toward. Controls near the top of
    /// the window should open downward so the bubble stays on screen.
    var edge: Edge = .top

    @State private var isHovering = false
    @Environment(\.onHelpHover) private var onHelpHover

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .overlay(alignment: edge == .top ? .bottom : .top) { bubble }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                onHelpHover(hovering)
            }
            .help(text)
            .accessibilityLabel("Help")
            .accessibilityValue(text)
    }

    @ViewBuilder
    private var bubble: some View {
        if isHovering {
            HelpBubble(text: text)
                .shadow(color: .black.opacity(0.45), radius: 16, y: edge == .top ? 4 : -4)
                .offset(y: edge == .top ? -20 : 20)
                // The bubble must never take the pointer, or hovering it would end
                // the hover that produced it and the whole thing would flicker.
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// The explanation panel itself, separate from the hover plumbing that reveals it.
struct HelpBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 250, alignment: .leading)
            .padding(11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12)))
    }
}

/// Lets deeply nested help markers tell the overlay that the pointer is parked on
/// one, so the auto-hide timer doesn't pull the controls away mid-sentence.
private struct HelpHoverKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    var onHelpHover: (Bool) -> Void {
        get { self[HelpHoverKey.self] }
        set { self[HelpHoverKey.self] = newValue }
    }
}

/// The wording shown by every help marker, kept together so the explanations can be
/// read as a set and stay consistent with each other.
enum HelpText {
    static let sensitivity = """
        How hard the visuals react. Loudness is already normalized automatically, so \
        reach for this only if a quiet track still looks flat — or pull it down if \
        everything sits pinned at maximum.
        """
    static let smoothing = """
        How quickly shapes settle after the music moves them. Low is twitchy and \
        precise; high is slow and glassy. This changes response time, not how much \
        detail is shown.
        """
    static let trails = """
        How long each frame lingers before fading. 0 is crisp, high leaves \
        comet-like streaks. Every visualization has its own default, so choosing a \
        different one resets this slider to whatever suits it.
        """
    static let colorDrift = """
        How fast the palette rotates through its colors over time, with a small \
        extra nudge on each beat. 0 holds the colors fixed.
        """
    static let quality = """
        Draws the visualization below the display's real resolution and scales it up, \
        trading a little sharpness for frame rate. Auto only does this above roughly \
        4K, where eight full-screen shaders start to cost real time.
        """
    static let hdr = """
        Lets bright highlights go past normal white on displays with brightness \
        headroom, so glows look genuinely luminous rather than clipped. No effect on \
        standard-range displays.
        """
    static let idleDrift = """
        With nothing playing, keeps the scene slowly moving instead of freezing on \
        black — a still visualizer reads as a crash. It never mimics real audio: the \
        motion stays far below what actual sound produces.
        """
    static let source = """
        Which audio to draw. "All system audio" follows everything your Mac plays; \
        picking a single app follows only that one, so you can visualize music while \
        a call runs on the same machine.
        """
    static let autoCycle = """
        Drifts to a different visualization on a timer, changing the palette every \
        third switch. Meant for leaving running at a party.
        """
    static let tempo = """
        Detected tempo, in beats per minute. It appears only once the estimate has \
        held steady for a while, so a blank space means the beat isn't clear enough \
        to trust yet.
        """
    static let stereoWidth = """
        How wide the stereo image is. The dots sit together for mono and spread \
        apart as the left and right channels diverge.
        """
}
