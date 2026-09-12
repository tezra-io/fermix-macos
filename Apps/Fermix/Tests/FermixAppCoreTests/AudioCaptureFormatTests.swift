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
}
