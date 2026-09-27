import Foundation
import Testing

@testable import FermixAppCore

/// The launch argument that starts the app hidden for a task (plan §4.0).
///
/// Parsing ships in every build, release included: a task can start the app
/// on any Mac running Fermix, not only a debug one.
@Suite("Background launch argument")
struct BackgroundLaunchRequestTests {
    @Test("a launch with no flag asks for nothing")
    func absentFlag() throws {
        #expect(try BackgroundLaunchRequest.parse(["/path/Fermix"]) == false)
        #expect(try BackgroundLaunchRequest.parse(["/path/Fermix", "--fixture"]) == false)
    }

    @Test("the flag asks to start hidden")
    func flagPresent() throws {
        #expect(try BackgroundLaunchRequest.parse(["/path/Fermix", "--background"]))
    }

    /// A repeated flag is the one that reads as though the launch was composed
    /// twice, and a launch argument that is quietly dropped is what makes a
    /// wrong configuration look like the one that was asked for.
    @Test("a repeated flag is refused")
    func repeatedFlag() {
        #expect(throws: BackgroundLaunchRequest.Refusal.flagRepeated) {
            try BackgroundLaunchRequest.parse(["/path/Fermix", "--background", "--background"])
        }
    }

    /// Every refusal has to say why, not just that. A sentence that does not
    /// name the flag sends the reader looking for a typo somewhere else.
    @Test("every refusal carries a sentence that names what was inspected")
    func refusalsSpeak() {
        let refusals: [BackgroundLaunchRequest.Refusal] = [.flagRepeated, .combinedWithFixture]

        for refusal in refusals {
            #expect(!refusal.sentence.isEmpty)
        }
        #expect(BackgroundLaunchRequest.Refusal.flagRepeated.sentence.hasPrefix(BackgroundLaunchRequest.flag))
        #expect(BackgroundLaunchRequest.Refusal.combinedWithFixture.sentence.contains(FixtureLaunchRequest.flag))
    }
}
