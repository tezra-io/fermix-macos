import SwiftUI

/// The sheets a press collects its action's needs in: the choice of size and
/// place, and the recovery passphrase. Each ends with the action's confirm,
/// in the engine's words, above the action's own label, so pressing it is
/// accepting the confirm and the passphrase never waits behind a second
/// question.
struct AlwaysOnAskContent: View {
    @ObservedObject var model: AlwaysOnModel
    let ask: AlwaysOnAsk

    var body: some View {
        switch ask {
        case .choice(let action):
            AlwaysOnChoiceSheet(model: model, action: action)
        case .passphrase(let action, let twice):
            AlwaysOnPassphraseSheet(model: model, action: action, twice: twice)
        case .token, .confirm:
            EmptyView()
        }
    }
}

/// The choice (`needs` `choice`): what the provider sells, by city, each
/// offer with its monthly price as given, the recommendation chosen until
/// the owner picks another.
struct AlwaysOnChoiceSheet: View {
    @ObservedObject var model: AlwaysOnModel
    let action: ManagementHomeAction

    @State private var choice: ManagementProvisionPick?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ProductStrings[.alwaysOnChangeTitle])
                .fermixType(Typography.style(.headline))
            AlwaysOnOffers(options: model.options, selected: selected) { choice = $0 }
            if let confirm = action.confirm {
                CueNote(text: confirm)
            }
            HStack(spacing: Spacing.s) {
                Spacer()
                if model.working == action.id { ProgressView().controlSize(.small) }
                Button(ProductStrings[.settingsSheetCancel], action: model.dismissAsk)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.working != nil)
                PrimaryAction(action.label, size: .row) {
                    guard let selected else { return }
                    Task { await model.submitChoice(selected) }
                }
                .disabled(selected == nil || model.working != nil)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.pickerSize.width, height: SheetMetrics.pickerSize.height)
    }

    /// The owner's pick, else the recommendation.
    private var selected: ManagementProvisionPick? {
        choice ?? model.options.value?.recommended
    }
}

/// The offers, by location, cheapest first, the one selected marked, under
/// the engine's sentence for the recommendation.
struct AlwaysOnOffers: View {
    let options: SettingsReadState<ManagementProvisionOptions>
    let selected: ManagementProvisionPick?
    let pick: (ManagementProvisionPick) -> Void

    var body: some View {
        switch options {
        case .loaded(let options):
            CueNote(text: options.sentence)
            Form {
                ForEach(options.locations, id: \.id) { location in
                    Section(location.city) {
                        ForEach(options.offers.filter { $0.location == location.id }, id: \.type) { offer in
                            row(offer, currency: options.currency)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .showsAmbientGround()
            .rowActions()
        case .unavailable(let sentence):
            CueNote(text: sentence, attention: true)
        case .requiresNewerEngine, .unread, .loading:
            ProgressView().controlSize(.small)
        }
    }

    private func row(_ offer: ManagementProvisionOffer, currency: String) -> some View {
        let offered = ManagementProvisionPick(type: offer.type, location: offer.location)

        return Button {
            pick(offered)
        } label: {
            HStack(spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(offer.description).fermixType(Typography.style(.callout))
                    CueNote(text: AlwaysOnPrices.shape(offer))
                }
                Spacer()
                Text(String(format: ProductStrings[.alwaysOnMonthlyFormat], AlwaysOnPrices.money(offer.totalMonthly, currency: currency)))
                    .fermixType(Typography.style(.calloutSmall))
                if selected == offered {
                    Image(systemName: "checkmark").foregroundStyle(Palette.accent.color).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An offer as the choice draws it: its shape, and its monthly total with
/// the IPv4 address, in the account's currency, as the provider gave it,
/// never rounded or summed here.
enum AlwaysOnPrices {
    static func money(_ amount: String, currency: String) -> String {
        guard let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else { return amount }

        return value.formatted(.currency(code: currency))
    }

    static func shape(_ offer: ManagementProvisionOffer) -> String {
        String(
            format: ProductStrings[.alwaysOnShapeFormat],
            offer.cores,
            offer.memoryGb.formatted(.number.precision(.fractionLength(0...1))),
            offer.diskGb
        )
    }
}

/// The recovery passphrase (`needs` `new_recovery_passphrase` or
/// `recovery_passphrase`): typed twice, and the two compared here, where none
/// is set; once where one is, which the engine checks. It lives in this
/// sheet until the one press sends it.
struct AlwaysOnPassphraseSheet: View {
    @ObservedObject var model: AlwaysOnModel
    let action: ManagementHomeAction
    let twice: Bool

    @State private var passphrase = ""
    @State private var again = ""
    @State private var mismatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ProductStrings[.alwaysOnPassphraseTitle])
                .fermixType(Typography.style(.headline))
            CuesPageForm {
                Section {
                    CueNote(text: ProductStrings[twice ? ProductStringKey.alwaysOnPassphraseBody : .alwaysOnPassphraseMoveBody])
                    LabeledContent(ProductStrings[.alwaysOnPassphraseField]) {
                        SecretInput(label: ProductStrings[.alwaysOnPassphraseField], value: $passphrase, onSubmit: {}, prompt: "")
                    }
                    if twice {
                        LabeledContent(ProductStrings[.alwaysOnPassphraseAgain]) {
                            SecretInput(label: ProductStrings[.alwaysOnPassphraseAgain], value: $again, onSubmit: {}, prompt: "")
                        }
                    }
                    if mismatch {
                        CueNote(text: ProductStrings[.alwaysOnPassphraseMismatch], attention: true)
                    }
                    if let confirm = action.confirm {
                        CueNote(text: confirm)
                    }
                }
            }
            HStack(spacing: Spacing.s) {
                Spacer()
                if model.working == action.id { ProgressView().controlSize(.small) }
                Button(ProductStrings[.settingsSheetCancel], action: model.dismissAsk)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.working != nil)
                PrimaryAction(action.label, size: .row, action: submit)
                    .disabled(passphrase.isEmpty || (twice && again.isEmpty) || model.working != nil)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
    }

    private func submit() {
        let typed = (passphrase, again)
        mismatch = twice && typed.0 != typed.1
        guard !mismatch else { return }

        Task { _ = await model.submitPassphrase(typed.0, again: twice ? typed.1 : nil) }
    }
}
