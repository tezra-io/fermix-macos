import Foundation
import Testing

@testable import FermixAppCore

/// A sound's levels as its waveform draws them (M66 §3.4): power on a
/// decibel curve from a floor of silence up to the loudest stretch, a quiet
/// room never stretched to fill, stretches shared out over what was really
/// decoded, and merged to the bars that fit. Pure: no file is read.
@Suite("Sound levels")
struct SoundLevelsTests {
    private static func close(_ lhs: [Float], _ rhs: [Float]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.0001 }
    }

    @Test("the starting numbers")
    func numbers() {
        #expect(SoundLevels.buckets == 80)
        #expect(SoundLevels.floor == -60)
        #expect(SoundLevels.quietTop == -30)
        #expect(AVFoundationSoundLevels.rate == 8_000)
    }

    /// -20 dBFS is the loudest and fills the height; -40 is halfway up the
    /// 40 dB from the floor; the floor and anything under it, or nothing at
    /// all, is silence.
    @Test("levels run in decibels from the floor to the loudest stretch")
    func decibelCurve() {
        let levels = SoundLevels(power: [1e-2, 1e-4, 1e-6, 1e-8, 0], seconds: 5)

        #expect(Self.close(levels.values, [1, 0.5, 0, 0, 0]))
        #expect(Self.close(SoundLevels(power: [1], seconds: 1).values, [1]))
    }

    /// Nothing louder than -30 dBFS is a quiet room: it is drawn against
    /// -30, so its noise is never stretched into a wave.
    @Test("a quiet sound is never stretched to fill the height")
    func quietRoom() {
        let levels = SoundLevels(power: [1e-4, 1e-5, 1e-7], seconds: 3)

        #expect(Self.close(levels.values, [20.0 / 30, 10.0 / 30, 0]))
        #expect(SoundLevels(power: [0, 0], seconds: 2).values == [0, 0])
        #expect(SoundLevels(power: [], seconds: 0).values.isEmpty)
    }

    @Test("things are shared out among parts evenly, never empty while there are any, never past the end")
    func spans() {
        #expect(SoundLevels.spans(of: 10, in: 4) == [0..<2, 2..<5, 5..<7, 7..<10])
        #expect(SoundLevels.spans(of: 3, in: 6) == [0..<1, 0..<1, 1..<2, 1..<2, 2..<3, 2..<3])
        #expect(SoundLevels.spans(of: 4, in: 4) == [0..<1, 1..<2, 2..<3, 3..<4])
        #expect(SoundLevels.spans(of: 0, in: 3) == [0..<0, 0..<0, 0..<0])
        #expect(SoundLevels.spans(of: 5, in: 0).isEmpty)
    }

    /// Fewer bars than stretches keep each one's loudest, so a peak is
    /// never lost; more repeat them.
    @Test("levels merge to the bars that fit, each the loudest it covers")
    func barsKeepPeaks() {
        let levels = SoundLevels(values: [0.1, 0.9, 0.2, 0.4], seconds: 4)

        #expect(levels.bars(2) == [0.9, 0.4])
        #expect(levels.bars(4) == levels.values)
        #expect(levels.bars(8) == [0.1, 0.1, 0.9, 0.9, 0.2, 0.2, 0.4, 0.4])
        #expect(levels.bars(0).isEmpty)
        #expect(SoundLevels(values: [], seconds: 0).bars(3) == [0, 0, 0])
    }

    @Test("power is summed in windows, the open one counted, and shared out as each stretch's mean, every frame counted")
    func powerWindows() {
        var power = SoundPower(windowFrames: 2)
        Self.add([1, 1, 0, 0, 0.5, 0.5], to: &power)

        #expect(power.stretches(3) == [1, 0, 0.25])
        #expect(power.stretches(1) == [2.5 / 6])
        #expect(power.frames == 6)

        Self.add([1], to: &power)
        #expect(power.stretches(4) == [1, 0, 0.25, 1])
        #expect(power.frames == 7)
        #expect(SoundPower(windowFrames: 2).stretches(4).isEmpty)
    }

    /// Nothing about a sound's length is known before it ends, so its
    /// windows are merged in pairs as it runs long: four times the capacity
    /// of single frames ends in windows of eight, with every mean kept.
    @Test("a long sound's windows merge in pairs, so it costs no more to hold than a short one")
    func powerMerges() {
        var power = SoundPower(windowFrames: 1)
        Self.add(Array(repeating: 1, count: SoundPower.capacity / 2) + Array(repeating: 0, count: SoundPower.capacity / 2), to: &power)

        #expect(power.windowFrames == 2)
        #expect(power.stretches(2) == [1, 0])

        Self.add(Array(repeating: 1, count: SoundPower.capacity * 3), to: &power)
        #expect(power.windowFrames == 8)
        #expect(power.frames == SoundPower.capacity * 4)
        #expect(power.stretches(1) == [Double(SoundPower.capacity * 7 / 2) / Double(SoundPower.capacity * 4)])
    }

    private static func add(_ samples: [Float], to power: inout SoundPower) {
        samples.withUnsafeBufferPointer { power.add($0) }
    }

    /// What AVFoundation cannot decode has no levels: its waveform keeps
    /// its resting bars. The file is a temporary one of its own.
    @Test("a file that is no sound has no levels")
    func noSound() async throws {
        let folder = try TemporaryDirectory()
        defer { folder.remove() }
        let broken = folder.url.appendingPathComponent("note.ogg", isDirectory: false)
        try Data("not a sound".utf8).write(to: broken)

        #expect(await AVFoundationSoundLevels().levels(of: broken, buckets: SoundLevels.buckets) == nil)
    }
}
