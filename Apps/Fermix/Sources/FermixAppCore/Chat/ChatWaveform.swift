import SwiftUI

/// How a sound's waveform lays out its bars: pure, so its rules are provable
/// without a view.
enum ChatWaveformLayout {
    /// From one bar's start to the next.
    static let pitch = ChatMetrics.soundBarWidth + ChatMetrics.soundBarGap

    /// How many bars fit `width`, the last with no gap after it.
    static func bars(fitting width: Double) -> Int {
        max(Int((width + ChatMetrics.soundBarGap) / pitch), 0)
    }

    /// Each bar's level: the sound's own, merged to `count` bars, or the
    /// resting bars, low and even, until they are read. Either way there are
    /// `count`, so nothing moves when the levels come.
    static func levels(_ levels: SoundLevels?, bars count: Int) -> [Float] {
        levels?.bars(count) ?? Array(repeating: ChatMetrics.soundRestingLevel, count: count)
    }

    /// How many bars a sound that has played `fraction` of itself has
    /// filled: a bar fills once the place passes its middle.
    static func played(_ fraction: Double, bars count: Int) -> Int {
        Int((min(max(fraction, 0), 1) * Double(count)).rounded())
    }

    /// A bar's height in a waveform `height` tall, never under the shortest,
    /// so silence still reads as a line.
    static func height(of level: Float, in height: Double) -> Double {
        let minimum = ChatMetrics.soundBarMinimum
        return minimum + Double(min(max(level, 0), 1)) * max(height - minimum, 0)
    }
}

/// A sound's waveform (M66 §3.4), a voice note's and a sound file's alike:
/// thin rounded bars as tall as the sound is loud along its length, the
/// bars played drawn in ink and the rest faint. It fills bar by bar as the
/// sound plays, moving over each tick rather than jumping, except under
/// Reduce Motion and under the pointer; a click or a drag on it seeks.
/// Before the sound's levels are read it draws the same bars, low and even.
struct ChatWaveform: View {
    /// The sound's levels; nil until they are read.
    let levels: SoundLevels?
    /// How much of the sound has played.
    let filled: Double
    let playing: Bool
    /// Where a click or a drag lands, as a fraction of the way along.
    let seek: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let count = ChatWaveformLayout.bars(fitting: proxy.size.width)
            let bars = ChatWaveformBars(levels: ChatWaveformLayout.levels(levels, bars: count))

            ZStack(alignment: .leading) {
                bars.fill(Palette.faint.color)
                bars.fill(Palette.ink.color)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: ChatWaveformLayout.pitch * Double(ChatWaveformLayout.played(filled, bars: count)))
                    }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, dragging, _ in dragging = true }
                    .onChanged { drag in
                        guard proxy.size.width > 0 else { return }

                        seek(drag.location.x / proxy.size.width)
                    }
            )
        }
        .animation(moves ? .linear(duration: AppPlayer.tick) : nil, value: filled)
    }

    private var moves: Bool {
        playing && !dragging && !reduceMotion
    }
}

/// The bars, one every pitch from the leading edge on whole points, each
/// centred on the waveform's middle line with rounded caps.
private struct ChatWaveformBars: Shape {
    let levels: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = ChatMetrics.soundBarWidth
        for (index, level) in levels.enumerated() {
            let height = ChatWaveformLayout.height(of: level, in: rect.height)
            let bar = CGRect(
                x: rect.minX + Double(index) * ChatWaveformLayout.pitch,
                y: rect.midY - height / 2,
                width: width,
                height: height
            )
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: width / 2, height: width / 2))
        }
        return path
    }
}
