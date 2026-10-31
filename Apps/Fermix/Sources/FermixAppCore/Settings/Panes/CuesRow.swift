import SwiftUI

/// The geometry the cue rows share.
enum CueRowMetrics {
    /// The dot before a status line. Decoration: the sentence beside it is
    /// the state, so the dot is never the only signal.
    static let dotSize: Double = 7
    /// A tag's height: a line of caption type with room round it, under the
    /// 24-point row controls so a tag never sets a row's height.
    static let tagHeight: Double = 18
    /// The room a tag keeps either side of its word.
    static let tagInset: Double = 6
}

/// The cue rows' times as the pane draws them: the time alone today, the day
/// and the time on any other day this year, and the year only beyond it.
enum CueTimes {
    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        }

        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day().hour().minute()
        guard calendar.isDate(date, equalTo: now, toGranularity: .year) else { return date.formatted(style.year()) }

        return date.formatted(style)
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The dot a cue row draws before its status sentence, from what the daemon
/// publishes for the row: whether it is switched on, whether its state asks
/// for attention, and the action it leads with. The sentence carries the
/// state; the dot only lets a list be read at a glance.
public enum CueTone {
    /// Off is quiet, a failure red, a secret or other step still owed amber,
    /// and the rest well.
    public static func source(_ source: ManagementCueSource) -> StatusTone {
        guard source.enabled else { return .neutral }
        if source.state.drawsAttention { return .fail }
        if let primary = source.primaryAction, source.actions.contains(primary) { return .warn }

        return .pass
    }

    /// A held watcher, or one with no model to filter with, asks for
    /// attention; a paused one is quiet.
    public static func watcher(_ watcher: ManagementCueWatcher) -> StatusTone {
        guard watcher.enabled else { return .neutral }
        if watcher.state.drawsAttention { return .warn }
        if watcher.task.paused || watcher.state == .paused { return .neutral }

        return .pass
    }

    /// A mandate that did not load, or that waits for its approval, is
    /// amber.
    public static func mandate(_ mandate: ManagementCueMandate) -> StatusTone {
        guard mandate.enabled else { return .neutral }
        if mandate.load.state != .active { return .warn }
        if CueMandateProjection.offersApprove(mandate) { return .warn }

        return .pass
    }

    /// A choice's requirement: met is well, a sign-in owed amber, and a
    /// state this build does not know quiet.
    public static func requirement(_ requirement: ManagementCueSourceForm.Requirement) -> StatusTone {
        switch requirement.state {
        case .ready: return .pass
        case .needsSignIn: return .warn
        case .unrecognized: return .neutral
        }
    }

    /// The subsystem as `cues.status` publishes it: running is well, a
    /// restart or memory still owed is amber, and off is quiet.
    public static func status(_ status: ManagementCueStatus) -> StatusTone {
        switch status.state {
        case .running: return .pass
        case .needsRestart, .needsMemory: return .warn
        case .off, .unrecognized: return .neutral
        }
    }

    /// The door: listening is well, a door that could not open amber, and a
    /// door with nothing to take quiet.
    public static func door(_ door: ManagementCueStatus.Door) -> StatusTone {
        switch door.state {
        case .listening: return .pass
        case .unavailable: return .warn
        case .notRunning, .unrecognized: return .neutral
        }
    }

    /// Whether a source's sentence is set in the attention style beside its
    /// dot: a failure, or a secret still owed, is the one thing on the list
    /// that may be loud.
    static func isLoud(_ tone: StatusTone) -> Bool {
        tone == .fail || tone == .warn
    }

    static func color(_ tone: StatusTone) -> Color {
        switch tone {
        case .pass: return Palette.success.color
        case .warn: return Palette.warning.color
        case .fail: return Palette.error.color
        case .neutral: return Palette.faint.color
        }
    }
}

/// A short state word set in a small capsule beside a row's name: a
/// mandate's mode.
public struct CueTagModel: Equatable, Sendable {
    public let text: String
    public let tone: StatusTone

    public init(text: String, tone: StatusTone) {
        precondition(!text.isEmpty, "a tag says something")
        self.text = text
        self.tone = tone
    }
}

struct CueTag: View {
    let tag: CueTagModel

    var body: some View {
        Text(tag.text)
            .fermixType(Typography.style(.caption))
            .foregroundStyle(tag.tone == .warn ? Palette.pillWarn.color : Palette.secondary.color)
            .lineLimit(1)
            .padding(.horizontal, CueRowMetrics.tagInset)
            .frame(height: CueRowMetrics.tagHeight)
            .background(Capsule().fill((tag.tone == .warn ? Palette.warnPillFill : Palette.chipFill).color))
            .overlay(Capsule().strokeBorder(
                (tag.tone == .warn ? Palette.warnPillBorder : Palette.hairline(.standard)).color,
                lineWidth: Stroke.hairline
            ))
            .fixedSize()
    }
}

/// One status line: the dot, then the daemon's sentence, quiet unless it
/// asks for attention.
struct CueStatusLine: View {
    let text: String
    let tone: StatusTone
    var attention = false
    /// How many lines a row gives it. A page gives it as many as it needs.
    var lines: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs - 2) {
            Image(systemName: "circle.fill")
                .font(.system(size: CueRowMetrics.dotSize))
                .foregroundStyle(CueTone.color(tone))
                .accessibilityHidden(true)

            CueNote(text: text, attention: attention)
                .lineLimit(lines)
        }
    }
}

/// One row of the pane's lists (§4.2 to §4.5): a symbol by kind or a
/// vendor's mark, the name, what qualifies it and a tag, then one status
/// line, with the row's own controls at the trailing edge. A row that opens
/// a page says so with the chevron and a hover fill; one that opens nothing
/// draws neither.
struct CueRow<Trailing: View>: View {
    let symbol: String
    /// A vendor's mark drawn in place of the symbol, where the row has one.
    var mark: VendorMark?
    let title: String
    var qualifier: String?
    var tag: CueTagModel?
    let status: String
    let tone: StatusTone
    var attention = false
    let accessibilityLabel: String
    /// Opens the row's page, or nil for a row that opens nothing.
    var open: (() -> Void)?
    @ViewBuilder let trailing: Trailing

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.s) {
            if let open {
                Button(action: open) { content(opens: true) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel)
            } else {
                content(opens: false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
            }

            trailing
        }
        // The hover fill reaches past the row's text by the same room it
        // keeps inside, so the tile and the name stay on the form's edge.
        .padding(.vertical, Spacing.xxs)
        .padding(.horizontal, Spacing.xs)
        .background(
            hovering && open != nil ? Palette.chipFill.color : .clear,
            in: RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous)
        )
        .padding(.horizontal, -Spacing.xs)
        .onHover { hovering = $0 }
    }

    private func content(opens: Bool) -> some View {
        HStack(spacing: Spacing.s) {
            if let mark {
                VendorMarkView(mark: mark, kind: .plugin, size: IntegrationMetrics.tileSize)
            } else {
                VendorMarkView(symbol: symbol, size: IntegrationMetrics.tileSize)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(title)
                        .fermixType(Typography.style(.callout).weight(.medium))
                        .foregroundStyle(Palette.ink.color)
                        .lineLimit(1)

                    if let qualifier, !qualifier.isEmpty {
                        Text(qualifier)
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.secondary.color)
                            .lineLimit(1)
                    }

                    if let tag {
                        CueTag(tag: tag)
                    }
                }

                CueStatusLine(text: status, tone: tone, attention: attention, lines: 2)
            }

            Spacer(minLength: 0)

            if opens {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint.color)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The top of a source's, a watcher's or a mandate's page: its tile, its
/// name over the daemon's sentence after the dot, and its switch where it
/// has one.
struct CuesPageHeading<Tile: View, Trailing: View>: View {
    let title: String
    let status: String
    let tone: StatusTone
    var attention = false
    @ViewBuilder let tile: Tile
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            tile

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fermixType(Typography.sheetTitle)
                    .foregroundStyle(Palette.ink.color)
                CueStatusLine(text: status, tone: tone, attention: attention)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Spacer(minLength: Spacing.s)

            trailing
        }
    }
}

/// A fact too long for the value column: its label, then its text under it
/// at the reading edge, as the owner wrote it or the daemon said it.
struct CuesStackedFact: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            Text(label)
            Text(text)
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A section's title, how many rows it holds where that helps, and its one
/// action beside it.
struct CuesSectionHeader: View {
    let title: ProductStringKey
    var count: Int?
    /// What the section is, behind the info beside its title.
    var info: ProductStringKey?
    let action: ProductStringKey?
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            DescriptorRowLabel(ProductStrings[title], info: info.map { ProductStrings[$0] })

            if let count, count > 0 {
                Text(count, format: .number)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.faint.color)
                    .monospacedDigit()
            }

            Spacer(minLength: Spacing.s)

            if let action {
                Button(ProductStrings[action], action: perform)
                    .buttonStyle(SecondaryButtonStyle(.row))
                    .textCase(nil)
            }
        }
    }
}

/// One line of the pane's small print, or the daemon's sentence in the
/// attention style where §4.9 asks for it.
struct CueNote: View {
    let text: String
    var attention = false

    var body: some View {
        Text(text)
            .fermixType(Typography.style(.calloutSmall))
            .foregroundStyle((attention ? Palette.warning : Palette.secondary).color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
