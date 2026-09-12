import SwiftUI

/// About you: how Fermix addresses the owner and keeps time (M34 §4).
///
/// A grouped form of four fields, every one of them prefilled from macOS, so
/// zero typing is a valid answer. The values are written by the Applying stage,
/// not here: a screen that wrote on every keystroke would restart the daemon
/// four times.
///
/// A refused write lands back here, so this screen says why. Without it the
/// person returned to a form that looked exactly as they left it, having been
/// told nothing — the same invisible refusal Connect your AI already draws.
struct AboutYouSurface: View {
    @ObservedObject var model: OnboardingModel

    @State private var choosingTimezone = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            SurfaceHeading(
                title: ProductStrings[.aboutYouTitle],
                subcopy: ProductStrings[.aboutYouSubcopy]
            )
            .padding(.bottom, Spacing.l)

            Form {
                Section {
                    TextField(ProductStrings[.aboutYouName], text: $model.answers.name)
                        .settingsTextField()

                    timezone

                    Picker(ProductStrings[.aboutYouStyle], selection: $model.answers.style) {
                        ForEach(AssistantStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField(ProductStrings[.aboutYouAssistantName], text: $model.answers.assistantName)
                        .settingsTextField()
                }
            }
            .formStyle(.grouped)
            .assistantFormChrome()

            refusals

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingMetrics.horizontalPadding)
        .padding(.top, Spacing.xs)
        .sheet(isPresented: $choosingTimezone) {
            TimeZoneSheet(selection: $model.answers.timezone) { choosingTimezone = false }
        }
    }

    /// What the last save earned: the gate that refused the advance, and the
    /// daemon's own sentence for the section this form writes.
    ///
    /// The row sentence is read under the section rather than under one field
    /// because the four values go out as one write, so a refusal is a refusal of
    /// all of them.
    @ViewBuilder
    private var refusals: some View {
        if let blocked = model.blocked {
            AssistantNotice(sentence: model.message(for: blocked)).padding(.top, Spacing.s)
        }

        if let sentence = writeRefusal {
            AssistantNotice(sentence: sentence).padding(.top, Spacing.s)
        }
    }

    /// The daemon's sentence for the write this form makes, from whichever of
    /// its keys the refusal was recorded under.
    private var writeRefusal: String? {
        let section = AboutYouAnswers.personalizationSection
        let keys = model.answers.personalizationValues.keys.sorted()

        return keys.lazy
            .compactMap { model.settings.message(for: SettingsDraftKey(section: section, key: $0)) }
            .first
    }

    /// The zone this Mac is in, named the way macOS names it. `Change…` opens a
    /// searchable list rather than a 400-row menu of raw identifiers, which is
    /// not how anything on this Mac chooses a time zone (M34 §4).
    private var timezone: some View {
        LabeledContent(ProductStrings[.aboutYouTimezone]) {
            HStack(spacing: Spacing.xs) {
                Text(TimeZoneChoice(identifier: model.answers.timezone).title)
                    .foregroundStyle(Palette.secondary.color)

                Button(ProductStrings[.aboutYouTimezoneChange]) { choosingTimezone = true }
            }
        }
    }
}

/// One time zone as a person reads it: the city, the zone's own name, and its
/// offset from GMT. The identifier is the value written; it is never the label.
struct TimeZoneChoice: Identifiable, Equatable, Sendable {
    let identifier: String

    var id: String { identifier }

    /// `New York · Eastern Standard Time · GMT-5`, with the underscore the wire
    /// identifier carries opened out.
    var title: String {
        let named = zone?.localizedName(for: .generic, locale: .current)
        let pieces = [city, named, offset].compactMap { $0 }.filter { !$0.isEmpty }

        return pieces.dropFirst().reduce(pieces.first ?? identifier) { ProductStrings.middot($0, $1) }
    }

    /// Everything a search has to look through, so typing `london`, `europe` or
    /// `gmt+0` all find the same row.
    var searchable: String {
        "\(identifier) \(title)".lowercased()
    }

    private var zone: TimeZone? { TimeZone(identifier: identifier) }

    private var city: String? {
        identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
    }

    private var offset: String? {
        guard let seconds = zone?.secondsFromGMT() else { return nil }

        let hours = seconds / 3_600
        let minutes = abs(seconds % 3_600) / 60
        let sign = seconds < 0 ? "-" : "+"
        guard minutes > 0 else { return String(format: "GMT%@%d", sign, abs(hours)) }

        return String(format: "GMT%@%d:%02d", sign, abs(hours), minutes)
    }

    /// Every zone macOS knows, in the order it lists them.
    static var all: [TimeZoneChoice] {
        TimeZone.knownTimeZoneIdentifiers.map(TimeZoneChoice.init(identifier:))
    }
}

/// Choosing a time zone: a searchable list of what macOS knows.
struct TimeZoneSheet: View {
    @Binding var selection: String
    let dismiss: () -> Void

    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(ProductStrings[.aboutYouTimezone])
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            TextField(
                ProductStrings[.aboutYouTimezone],
                text: $query,
                prompt: Text(ProductStrings[.aboutYouTimezoneSearchPrompt])
            )
            .labelsHidden()

            List(matching, selection: Binding(get: { selection }, set: { chosen in
                guard let chosen else { return }

                selection = chosen
                dismiss()
            })) { choice in
                Text(choice.title).tag(choice.id)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetCancel], action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.pickerSize.width, height: SheetMetrics.pickerSize.height)
    }

    private var matching: [TimeZoneChoice] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return TimeZoneChoice.all }

        return TimeZoneChoice.all.filter { $0.searchable.contains(needle) }
    }
}
