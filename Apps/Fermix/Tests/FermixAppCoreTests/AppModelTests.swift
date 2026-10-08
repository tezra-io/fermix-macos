import Foundation
import Testing

@testable import FermixAppCore

/// The app's own presentation state. A call's facts are `VoiceCallModel`'s and
/// are proven in `VoiceCallModelTests`.
@Suite("App model")
@MainActor
struct AppModelTests {
    /// The attention badge is a claim about the daemon, so a launch that has
    /// not asked it anything must not raise one.
    @Test("a launch that has asked the daemon nothing does not claim attention")
    func launchDoesNotClaimAttention() {
        let model = AppModel()

        #expect(model.menuGlyph == .starting)
        #expect(model.needsAttention == false)
    }
}
