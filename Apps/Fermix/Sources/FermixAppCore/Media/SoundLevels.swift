import AVFoundation
import Foundation

/// A sound's loudness along its length (M66 §3.4): one value for each of a
/// fixed number of equal stretches of it, from 0, silence, to 1, its
/// loudest, and that length as decoded. What a sound's waveform is drawn
/// from, read in the app from the sound itself, as a tile's thumbnail is:
/// the engine decodes nothing.
struct SoundLevels: Equatable, Sendable {
    /// How many stretches a sound is read in: as many bars as fit the
    /// widest player, so a waveform's drawing only ever merges them.
    static let buckets = 80
    /// The quietest a stretch is heard at, in decibels below full scale:
    /// anything quieter is silence.
    static let floor: Float = -60
    /// The least the loudest stretch is taken to be: a sound with nothing
    /// louder is a quiet room, drawn low, never stretched to fill the height.
    static let quietTop: Float = -30

    let values: [Float]
    /// How long the sound is, in seconds: the frames decoded over the rate
    /// they were decoded at, which is the length its row goes by once it is
    /// known (`ChatSoundState.length`).
    let seconds: Double

    init(values: [Float], seconds: Double) {
        self.values = values
        self.seconds = seconds
    }

    /// Levels from each stretch's mean power, the mean of its samples'
    /// squares, on a decibel curve, as the ear hears loudness: from the
    /// floor, silence, up to the loudest stretch, or -30 dBFS where nothing
    /// is louder. Quiet speech still stands up, the loudest moment fills the
    /// height, and a quiet room stays a line.
    init(power: [Double], seconds: Double) {
        let decibels = power.map { $0 > 0 ? Float(10 * log10($0)) : Self.floor }
        let top = max(decibels.max() ?? Self.floor, Self.quietTop)

        values = decibels.map { min(max(($0 - Self.floor) / (top - Self.floor), 0), 1) }
        self.seconds = seconds
    }

    /// What it holds, which the chat's previews count in their cache.
    var bytes: Int { values.count * MemoryLayout<Float>.stride }

    /// The levels merged to `count` bars, each the loudest of the stretches
    /// it covers, so a peak is never lost.
    func bars(_ count: Int) -> [Float] {
        Self.spans(of: values.count, in: count).map { values[$0].max() ?? 0 }
    }

    /// `count` things shared out in order among `parts`, as evenly as they
    /// go: every part has at least one where there is any, a part may share
    /// one with its neighbour where there are fewer things than parts, and
    /// none reaches past the end.
    static func spans(of count: Int, in parts: Int) -> [Range<Int>] {
        (0..<max(parts, 0)).map { part in
            let lower = part * count / parts
            return lower..<min(count, max(lower + 1, (part + 1) * count / parts))
        }
    }
}

/// A sound's power as it is decoded, summed in short windows of equal
/// length, and merged in pairs whenever there would be `capacity` of them:
/// a long sound costs no more to hold than a short one, and nothing about
/// its length need be known before it ends. AVFoundation misreads an Ogg
/// Opus voice note's length (9.36 s for one of 6.69 s, measured), so the
/// stretches are shared out over what was really decoded.
struct SoundPower {
    /// Windows held at most: a power of two, so every merge is of pairs.
    static let capacity = 1_024

    /// Frames in a window, doubled at each merge.
    private(set) var windowFrames: Int
    /// Every frame added.
    private(set) var frames = 0
    private var windows: [Window] = []
    private var open = Window()

    private struct Window {
        var sum: Double = 0
        var frames = 0
    }

    init(windowFrames: Int) {
        self.windowFrames = windowFrames
    }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        frames += samples.count
        for sample in samples {
            open.sum += Double(sample * sample)
            open.frames += 1
            if open.frames == windowFrames { close() }
        }
    }

    /// Each of `count` equal stretches' mean power, the window still open
    /// among them; none where nothing was decoded.
    func stretches(_ count: Int) -> [Double] {
        let all = open.frames > 0 ? windows + [open] : windows
        guard !all.isEmpty else { return [] }

        return SoundLevels.spans(of: all.count, in: count).map { span in
            let sum = all[span].reduce(0) { $0 + $1.sum }
            let frames = all[span].reduce(0) { $0 + $1.frames }
            return frames > 0 ? sum / Double(frames) : 0
        }
    }

    private mutating func close() {
        windows.append(open)
        open = Window()
        guard windows.count == Self.capacity else { return }

        windows = stride(from: 0, to: windows.count, by: 2).map { index in
            Window(sum: windows[index].sum + windows[index + 1].sum, frames: windows[index].frames + windows[index + 1].frames)
        }
        windowFrames *= 2
    }
}

/// What a sound's levels are read by: AVFoundation in the product, a fake in
/// tests, which open no file. Nonisolated, since the chat's previews read
/// them off the main thread.
protocol SoundLevelReading: Sendable {
    /// The levels of `file`'s sound in `buckets` stretches, or nil where it
    /// has none AVFoundation can decode. It stops when the task asking for
    /// them is cancelled.
    func levels(of file: URL, buckets: Int) async -> SoundLevels?
}

/// AVFoundation's reading: the file's first audio track decoded to mono
/// 32-bit float PCM at a low rate, its power summed as each buffer comes
/// (`SoundPower`) and no sample kept, until the track ends or the task is
/// cancelled. A voice note of a few seconds takes a few milliseconds.
struct AVFoundationSoundLevels: SoundLevelReading {
    /// The rate a sound is decoded at: plenty for its loudness, and a sixth
    /// of what a phone records.
    static let rate = 8_000.0

    func levels(of file: URL, buckets: Int) async -> SoundLevels? {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.settings)
        guard reader.canAdd(output) else { return nil }

        reader.add(output)
        guard reader.startReading() else { return nil }

        var power = SoundPower(windowFrames: Int(Self.rate) / 100)
        while !Task.isCancelled, let buffer = output.copyNextSampleBuffer() {
            Self.add(buffer, to: &power)
        }
        guard reader.status == .completed, !Task.isCancelled else {
            reader.cancelReading()
            return nil
        }

        let stretches = power.stretches(buckets)
        return stretches.isEmpty ? nil : SoundLevels(power: stretches, seconds: Double(power.frames) / Self.rate)
    }

    /// Mono, native-endian float, at the low rate: AVFoundation mixes the
    /// channels down and resamples as it decodes.
    private static var settings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: rate
        ]
    }

    /// One decoded buffer's samples, read where they lie.
    private static func add(_ buffer: CMSampleBuffer, to power: inout SoundPower) {
        try? buffer.withAudioBufferList { list, _ in
            for audio in list {
                guard let data = audio.mData else { continue }

                let count = Int(audio.mDataByteSize) / MemoryLayout<Float>.size
                power.add(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            }
        }
    }
}
