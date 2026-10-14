import AVFoundation
import Foundation

/// The capture tap's conversion to the call's 24 kHz mono, built for the format
/// each buffer arrives in, and the count of what it sent.
///
/// The device under a tap can change its format after the tap was installed
/// (the first voice processing bring-up in a process, a microphone plugged in
/// during a call), and a converter built once for the other format garbles or
/// drops the audio without a word: on 2026-10-08 a call's first minute reached
/// the provider as fragments while the processed voice itself was clear. So a
/// buffer in a new format gets a converter of its own, and the report says
/// afterwards how much audio the tap sent and whether any of it failed.
///
/// The converter is used on the tap's thread alone; the counts are written
/// there and read once the tap is removed, behind a lock.
final class CaptureConversion {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter
    private let lock = NSLock()
    private var samplesSent = 0
    private var failures = 0
    private var formats: [String]

    init?(from format: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AudioController.captureConverter(from: format, to: outputFormat) else { return nil }

        self.outputFormat = outputFormat
        self.converter = converter
        self.formats = [AudioController.describe(format)]
    }

    /// The buffer as the call's PCM16, or nothing when it cannot be converted.
    func pcm16(from buffer: AVAudioPCMBuffer) -> Data {
        guard let converter = converter(for: buffer.format) else {
            lock.withLock { failures += 1 }
            return Data()
        }

        let data = AudioController.pcm16Data(from: buffer, converter: converter, outputFormat: outputFormat)
        lock.withLock {
            if data.isEmpty {
                failures += 1
            } else {
                samplesSent += data.count / MemoryLayout<Int16>.size
            }
        }
        return data
    }

    /// What the tap sent, for the log.
    func report() -> String {
        lock.withLock {
            let seconds = Double(samplesSent) / outputFormat.sampleRate
            let sent = (seconds * 10).rounded() / 10
            return "\(sent) s of audio sent, \(failures) buffers not converted, formats \(formats.joined(separator: " then "))"
        }
    }

    private func converter(for format: AVAudioFormat) -> AVAudioConverter? {
        if converter.inputFormat == format { return converter }
        guard let rebuilt = AudioController.captureConverter(from: format, to: outputFormat) else { return nil }

        converter = rebuilt
        lock.withLock { formats.append(AudioController.describe(format)) }
        return rebuilt
    }
}
