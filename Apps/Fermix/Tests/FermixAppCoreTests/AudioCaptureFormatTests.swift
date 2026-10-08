import AVFoundation
import Testing
@testable import FermixAppCore

/// The capture tap is installed only at a format the hardware can honour.
@Suite("Audio capture format")
struct AudioCaptureFormatTests {
    private let nominal = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private let hardware = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    /// What the input node reports with no default input device: no sample
    /// rate and no channels.
    private let noDevice = AVAudioFormat()

    @Test("no input device means no capture, whatever the bus output says")
    func noDeviceRefuses() {
        #expect(noDevice.sampleRate == 0)
        #expect(noDevice.channelCount == 0)
        #expect(AudioController.captureFormat(hardware: noDevice, output: nominal) == nil)
    }

    @Test("a live device captures at the bus output format")
    func liveDeviceUsesTheBusFormat() {
        #expect(AudioController.captureFormat(hardware: hardware, output: nominal) == nominal)
    }

    @Test("a live device whose bus output is not ready captures at the hardware format")
    func liveDeviceFallsToHardware() {
        #expect(AudioController.captureFormat(hardware: hardware, output: noDevice) == hardware)
    }

    /// What macOS hands the tap with voice processing on for a two-channel USB
    /// microphone (2026-09-28): six discrete channels at 48 kHz.
    private let voiceProcessed = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        interleaved: false,
        channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 6)!
    )

    @Test("a voice-processed input of six channels reaches the call as voice, not silence")
    func voiceProcessedInputIsNotSilence() throws {
        let call = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: voiceProcessed, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let channels = try #require(buffer.floatChannelData)

        for channel in 0..<6 {
            for frame in 0..<4_800 {
                channels[channel][frame] = 0.5 * sin(Float(frame) * 2 * .pi * 440 / 48_000)
            }
        }

        let converter = try #require(AudioController.captureConverter(from: voiceProcessed, to: call))
        let pcm = AudioController.pcm16Data(from: buffer, converter: converter, outputFormat: call)

        #expect(pcm.count > 0)
        #expect(PCM16.isVoiced(pcm))
    }

    /// A 440 Hz tone on every channel of `format`, 100 ms of it.
    private func tone(_ format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try #require(buffer.floatChannelData)

        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                channels[channel][frame] = 0.5 * sin(Float(frame) * 2 * .pi * 440 / Float(format.sampleRate))
            }
        }

        return buffer
    }

    /// The device under a tap can change its format after the tap was
    /// installed (2026-10-08: the first voice processing bring-up settled from
    /// four channels to six). A converter built once for the old format lost
    /// the call's audio without a word; each format gets its own, and the
    /// report says what was sent.
    @Test("a buffer in a format the tap was not installed at is converted too, and the report counts both")
    func conversionFollowsTheBuffersFormat() throws {
        let call = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        let fourChannels = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!
        )
        let conversion = try #require(CaptureConversion(from: fourChannels, to: call))

        #expect(PCM16.isVoiced(conversion.pcm16(from: try tone(fourChannels))))
        #expect(PCM16.isVoiced(conversion.pcm16(from: try tone(voiceProcessed))))
        #expect(conversion.report() == "0.2 s of audio sent, 0 buffers not converted, formats 4 ch at 48000 Hz then 6 ch at 48000 Hz")
    }
}
