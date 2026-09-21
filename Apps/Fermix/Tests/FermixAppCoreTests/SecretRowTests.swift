import Foundation
import Testing

@testable import FermixAppCore

/// The rules a secret is typed under, now that it is typed in the row that owns
/// it rather than in a sheet of its own (M34 §7.4).
///
/// `SecretDraft` is the whole of what the field holds, so every rule the old
/// sheet enforced with its own state is proven here without a window: a blank
/// is never sent, one store is in flight at a time, a refusal keeps what was
/// typed, and a confirmation drops it.
@Suite("Secret entry")
@MainActor
struct SecretRowTests {
    @Test("a blank is never sent")
    func blankIsNeverSent() {
        var draft = SecretDraft()

        #expect(!draft.canStore)
        #expect(draft.beginStoring() == nil)
        #expect(!draft.storing, "nothing went out, so nothing is in flight")
    }

    /// Return and the button both reach the same method, and a person presses
    /// Return twice. The second press must not send the value again.
    @Test("a second store while one is in flight sends nothing")
    func oneStoreAtATime() {
        var draft = SecretDraft()
        draft.value = "sk-live"

        #expect(draft.beginStoring() == "sk-live")
        #expect(draft.storing)
        #expect(!draft.canStore)
        #expect(draft.beginStoring() == nil)
    }

    /// `secret_store_failed` means the value never reached the store. Dropping
    /// it would make the person type it again, which is the one thing the row
    /// exists to avoid.
    @Test("a refusal keeps what was typed and allows another attempt")
    func refusalKeepsTheValue() {
        var draft = SecretDraft()
        draft.value = "sk-live"
        _ = draft.beginStoring()

        draft.finish(refusal: "The keychain is locked.")

        #expect(draft.value == "sk-live")
        #expect(!draft.storing)
        #expect(draft.canStore)
    }

    @Test("a confirmed store drops the value from this process's state")
    func confirmationDropsTheValue() {
        var draft = SecretDraft()
        draft.value = "sk-live"
        _ = draft.beginStoring()

        draft.finish(refusal: nil)

        #expect(draft.value.isEmpty)
        #expect(!draft.storing)
        #expect(!draft.canStore)
    }

    @Test("cancel, Escape and the row going away all drop the value")
    func discardDropsTheValue() {
        var draft = SecretDraft()
        draft.value = "sk-half-typed"

        draft.discard()

        #expect(draft.value.isEmpty)
        #expect(draft.beginStoring() == nil)
    }

    /// The draft and the model together, the way the row drives them: the
    /// daemon's own sentence comes back on a refusal and the value is still
    /// there, and the daemon saw the value exactly once per attempt.
    @Test("a refused secret.set leaves the daemon's sentence and the typed value")
    func refusedStoreThroughTheModel() async throws {
        let harness = try SettingsHarness()
        harness.gateway.v2Failures[.secretSet] = ManagementRefusal.daemon(
            .secretStoreFailed,
            "The keychain is locked."
        )
        var draft = SecretDraft()
        draft.value = "sk-live"

        let first = draft.beginStoring()
        let sent = try #require(first)
        let sentence = await harness.model.setSecret(id: "openai_api_key", value: sent)
        draft.finish(refusal: sentence)

        #expect(sentence == "The keychain is locked.")
        #expect(draft.value == "sk-live")
        #expect(harness.gateway.storedSecrets == [SecretWrite(id: "openai_api_key", value: "sk-live")])

        // The retry is the same gesture, and it clears on success.
        harness.gateway.v2Failures[.secretSet] = nil
        let second = draft.beginStoring()
        let again = try #require(second)
        draft.finish(refusal: await harness.model.setSecret(id: "openai_api_key", value: again))

        #expect(draft.value.isEmpty)
        #expect(harness.gateway.storedSecrets.count == 2)
    }

    /// Escape belongs to a field while it is being edited (M34 §3.1), and a
    /// secret field claims it the way a text row does: by key, through the one
    /// model. The claim is released by name, so a row that goes away with the
    /// field still focused cannot leave the next Escape swallowed.
    @Test("a secret field's Escape claim is released by the field that made it")
    func escapeClaimIsReleasedByName() throws {
        let harness = try SettingsHarness()
        let secret = SettingsDraftKey(section: "secret", key: "openai_api_key")
        let other = SettingsDraftKey(section: "providers.openai", key: "default_model")

        harness.model.beginEditing(secret)
        #expect(harness.model.editingRow == secret)

        // A different field letting go does not release this one.
        harness.model.endEditing(other)
        #expect(harness.model.editingRow == secret)

        let before = harness.model.editReverts
        harness.model.revertEdit()
        #expect(harness.model.editReverts == before + 1, "Escape reaches the field")

        harness.model.endEditing(secret)
        #expect(harness.model.editingRow == nil)

        // With nothing being edited, Escape is the window's again.
        harness.model.revertEdit()
        #expect(harness.model.editReverts == before + 1)
    }
}
