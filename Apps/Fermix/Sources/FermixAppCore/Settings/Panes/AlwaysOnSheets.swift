import SwiftUI

/// What Details holds (§7): on `choose` the server's shape and the price with
/// its IPv4 address and VAT, and how Hetzner bills; on `ready` the server's
/// facts and until when it waits; on `on` the server, each backup, the space
/// this Mac's copies take, the disk, what lives on the server, Back up now and
/// Replace the server; on a problem what Fermix last saw and when, and the
/// other actions. Every value is the engine's; the labels are the app's.
struct AlwaysOnDetails: View {
    let screen: AlwaysOnScreen
    @ObservedObject var model: AlwaysOnModel

    /// Whether the screen has Details at all.
    static func shows(_ screen: AlwaysOnScreen) -> Bool {
        switch screen.kind {
        case .choose, .ready, .on, .problem: return true
        default: return false
        }
    }

    var body: some View {
        switch screen.kind {
        case .choose: choose
        case .ready: server(screen.detail.server)
        case .on: on
        case .problem: problem
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var choose: some View {
        if let options = model.options.value, let pick = model.pick, let offer = options.offer(pick) {
            AlwaysOnFact(text: AlwaysOnPrices.shape(offer))
            AlwaysOnFact(text: AlwaysOnPrices.price(offer, in: options))
        }
        if let billing = screen.detail.billing {
            AlwaysOnFact(text: billing)
        }
    }

    @ViewBuilder
    private func server(_ server: ManagementHomeSummaryServer?) -> some View {
        if let server {
            AlwaysOnFactRow(label: .alwaysOnServerName, value: server.name)
            AlwaysOnFactRow(label: .alwaysOnServerType, value: server.type)
            AlwaysOnFactRow(label: .alwaysOnServerLocation, value: server.location)
            AlwaysOnFactRow(label: .alwaysOnServerAddress, value: server.ipv4)
            AlwaysOnFactRow(label: .alwaysOnServerSystem, value: server.system)
            AlwaysOnFactRow(label: .alwaysOnServerVersion, value: server.version)
        }
        if let until = screen.detail.waitsUntil {
            AlwaysOnFact(text: String(format: ProductStrings[.alwaysOnWaitsUntilFormat], AlwaysOnFormat.time(until)))
        }
    }

    @ViewBuilder
    private var on: some View {
        server(screen.detail.server)
        ForEach(screen.detail.backups ?? [], id: \.place) { backup in
            AlwaysOnFactRow(label: .alwaysOnBackupPlaceFormat, format: backup.place, value: AlwaysOnFormat.time(backup.at))
        }
        if let bytes = screen.detail.copiesBytes {
            AlwaysOnFactRow(label: .alwaysOnCopies, value: AlwaysOnFormat.bytes(bytes))
        }
        if let used = screen.detail.diskUsed {
            AlwaysOnFactRow(label: .alwaysOnDisk, value: AlwaysOnFormat.percent(used))
        }
        if let data = screen.detail.data {
            AlwaysOnFact(text: data)
        }
        actions
    }

    @ViewBuilder
    private var problem: some View {
        if let note = screen.detail.note {
            AlwaysOnFact(text: note)
        }
        if let seen = screen.detail.seenAt {
            AlwaysOnFact(text: String(format: ProductStrings[.alwaysOnSeenFormat], AlwaysOnFormat.time(seen)))
        }
        ForEach(screen.warnings, id: \.id) { item in
            CueNote(text: item.sentence, attention: item.status == .block)
        }
        actions
    }

    private var actions: some View {
        ForEach(screen.alternatives, id: \.self) { action in
            AlwaysOnLinkAction(action: action, model: model)
        }
    }
}

/// One line of Details in the engine's words.
struct AlwaysOnFact: View {
    let text: String

    var body: some View {
        Text(text)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle(Palette.secondary.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One labelled fact, drawn only where the engine gave its value.
struct AlwaysOnFactRow: View {
    let label: ProductStringKey
    var format: String?
    let value: String?

    var body: some View {
        if let value {
            LabeledContent(format.map { String(format: ProductStrings[label], $0) } ?? ProductStrings[label]) {
                Text(value)
                    .textSelection(.enabled)
            }
            .fermixType(Typography.style(.calloutSmall))
        }
    }
}

/// The engine's values, drawn for a person: its times in this Mac's own
/// style, a size and a fraction. Never a value the engine did not give.
enum AlwaysOnFormat {
    static func time(_ text: String) -> String {
        guard let date = ManagementCueTime.date(text) else { return text }

        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

/// The prices of an offer, as Hetzner gave them: monthly and gross, in the
/// account's currency, never rounded or summed here.
enum AlwaysOnPrices {
    static func money(_ amount: String, currency: String) -> String {
        guard let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else { return amount }

        return value.formatted(.currency(code: currency))
    }

    /// The choice in the sentence the recommendation is said in: type, city
    /// and the monthly total with its IPv4 address.
    static func choice(_ offer: ManagementProvisionOffer, in options: ManagementProvisionOptions) -> String {
        String(
            format: ProductStrings[.alwaysOnChoiceFormat],
            offer.description,
            options.city(offer.location) ?? offer.location.wireValue,
            money(offer.totalMonthly, currency: options.currency)
        )
    }

    static func shape(_ offer: ManagementProvisionOffer) -> String {
        String(
            format: ProductStrings[.alwaysOnShapeFormat],
            offer.cores,
            offer.memoryGb.formatted(.number.precision(.fractionLength(0...1))),
            offer.diskGb
        )
    }

    static func price(_ offer: ManagementProvisionOffer, in options: ManagementProvisionOptions) -> String {
        String(
            format: ProductStrings[.alwaysOnPriceFormat],
            money(offer.monthly, currency: options.currency),
            money(offer.ipv4Monthly, currency: options.currency)
        )
    }
}

/// Change (§7): the sizes and locations Hetzner has in stock, each with its
/// monthly price as given.
struct AlwaysOnChangeSheet: View {
    @ObservedObject var model: AlwaysOnModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ProductStrings[.alwaysOnChangeTitle])
                .fermixType(Typography.style(.headline))
            AlwaysOnOffers(model: model, selected: model.pick) { pick in
                model.choose(pick)
                done()
            }
            HStack {
                Spacer()
                Button(ProductStrings[.settingsSheetDone], action: done)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.pickerSize.width, height: SheetMetrics.pickerSize.height)
    }
}

/// The offers, by location, cheapest first, the one selected marked.
struct AlwaysOnOffers: View {
    @ObservedObject var model: AlwaysOnModel
    let selected: ManagementProvisionPick?
    let pick: (ManagementProvisionPick) -> Void

    var body: some View {
        switch model.options {
        case .loaded(let options):
            Form {
                ForEach(options.locations, id: \.id) { location in
                    Section(location.city) {
                        ForEach(options.offers.filter { $0.location == location.id }, id: \.type) { offer in
                            row(offer, options: options)
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

    private func row(_ offer: ManagementProvisionOffer, options: ManagementProvisionOptions) -> some View {
        let chosen = selected == ManagementProvisionPick(type: offer.type, location: offer.location)

        return Button {
            pick(ManagementProvisionPick(type: offer.type, location: offer.location))
        } label: {
            HStack(spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(offer.description).fermixType(Typography.style(.callout))
                    CueNote(text: AlwaysOnPrices.shape(offer))
                }
                Spacer()
                Text(String(format: ProductStrings[.alwaysOnMonthlyFormat], AlwaysOnPrices.money(offer.totalMonthly, currency: options.currency)))
                    .fermixType(Typography.style(.calloutSmall))
                if chosen {
                    Image(systemName: "checkmark").foregroundStyle(Palette.accent.color).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Replace the server (§7, on Details): a new server of the size and in the
/// location chosen, then the same Move now; Fermix deletes the old one once
/// the move is done.
struct AlwaysOnReplaceSheet: View {
    @ObservedObject var model: AlwaysOnModel
    @State private var choice: ManagementProvisionPick?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ProductStrings[.alwaysOnReplaceTitle])
                .fermixType(Typography.style(.headline))
            CueNote(text: ProductStrings[.alwaysOnReplaceBody])
            AlwaysOnOffers(model: model, selected: choice ?? model.pick) { choice = $0 }
            HStack(spacing: Spacing.s) {
                Spacer()
                Button(ProductStrings[.settingsSheetCancel], action: model.closeReplace)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .keyboardShortcut(.cancelAction)
                PrimaryAction(ProductStrings[.alwaysOnReplaceCreate], size: .row) {
                    guard let replacement = choice ?? model.pick else { return }
                    Task { await model.replaceServer(with: replacement) }
                }
                .disabled((choice ?? model.pick) == nil || model.working != nil)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.pickerSize.width, height: SheetMetrics.pickerSize.height)
        .task { if model.options.value == nil { await model.readOptions() } }
    }
}

/// Move now's question for the recovery passphrase, where none is held for
/// this move: typed twice, since the move encrypts the backups to it.
struct AlwaysOnMovePassphraseSheet: View {
    @ObservedObject var model: AlwaysOnModel

    @State private var passphrase = ""
    @State private var again = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(ProductStrings[.alwaysOnPassphraseTitle])
                .fermixType(Typography.style(.headline))
            CuesPageForm {
                Section {
                    CueNote(text: ProductStrings[.alwaysOnPassphraseMoveBody])
                    AlwaysOnPassphraseFields(passphrase: $passphrase, again: $again)
                    if let refusal = model.passphraseRefusal {
                        CueNote(text: refusal, attention: true)
                    }
                }
            }
            HStack(spacing: Spacing.s) {
                Spacer()
                Button(ProductStrings[.settingsSheetCancel], action: model.dismissMovePassphrase)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .keyboardShortcut(.cancelAction)
                PrimaryAction(ProductStrings[.alwaysOnPassphraseContinue], size: .row) {
                    let typed = (passphrase, again)
                    Task { await model.moveWithPassphrase(typed.0, again: typed.1) }
                }
                .disabled(passphrase.isEmpty || again.isEmpty)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
    }
}
