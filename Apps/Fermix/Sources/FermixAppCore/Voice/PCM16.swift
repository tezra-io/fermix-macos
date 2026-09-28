import Foundation

/// How loud a chunk of PCM16 audio is, and whether it carries voice.
///
/// The one owner of that question for the audio the daemon relays. Live never
/// stops its output: between replies it sends digital silence, one chunk every
/// 100 ms for the whole call (measured on the dev engine on 2026-09-28: 249
/// chunks in a 27 second call, 7 of them voice). Padding plays like any audio,
/// but it is not speech, and a reply has finished playing when its voice has.
enum PCM16 {
    /// int16 RMS. Live's voice measured 244 to 3,667 per 100 ms chunk and its
    /// padding 0 to 49. The engine's `LiveTurn` draws the same line.
    static let voicedRMS: Float = 100

    /// Root mean square of the chunk, in int16 units.
    static func rms(_ data: Data) -> Float {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return 0 }

        return data.withUnsafeBytes { raw -> Float in
            let samples = raw.bindMemory(to: Int16.self)
            var sumSquares: Float = 0
            for index in 0..<count {
                let sample = Float(samples[index])
                sumSquares += sample * sample
            }
            return (sumSquares / Float(count)).squareRoot()
        }
    }

    static func isVoiced(_ data: Data) -> Bool {
        rms(data) >= voicedRMS
    }

    /// Audio that does not decode is not voice.
    static func isVoiced(base64 encoded: String) -> Bool {
        guard let data = Data(base64Encoded: encoded) else { return false }

        return isVoiced(data)
    }
}
