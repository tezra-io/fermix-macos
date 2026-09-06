import SwiftUI

/// The one grouped `Form` every Settings pane is drawn inside.
///
/// It exists so the window has exactly one form container: the panes supply
/// sections, and nothing below this line draws a box of its own.
///
/// No inline scrollbars (decision D4, owner directive of 2026-09-03: "try to
/// avoid the inline scrollbar"). A `Form` scrolls only when its content is
/// taller than the window, so a short pane does not scroll at all; the
/// indicators are never drawn, and the top and bottom edges take the system's
/// own scroll edge effect where it exists. There is no second scroll view
/// inside a pane: a long list either collapses in place or opens a sheet.
struct SettingsPaneForm<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
        .paneScrollEdges()
        .frame(maxWidth: WindowMetrics.settingsContentMaxWidth)
        .frame(maxWidth: .infinity)
        .navigationTitle(title)
    }
}

/// The pane form's edge treatment: the system's soft scroll edge effect on
/// macOS 26, and nothing on the macOS 15 floor, where the system draws the
/// same fade under a grouped form itself.
///
/// Module wide rather than file private, because it is the edge rule for every
/// scroll container a pane owns, and one pane builds its own rather than taking
/// the form above.
extension View {
    @ViewBuilder
    func paneScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

/// Every section the daemon assigned to one pane, rendered from its descriptor
/// (M34 §7.7).
///
/// Labels, footers, options and bounds are all the daemon's. There is no field
/// inventory here: a scalar key added in the engine appears the moment the
/// contract is re-vendored, with no Swift beyond this file.
struct DescriptorForm: View {
    @ObservedObject var model: SettingsModel
    let sections: [ManagementSettingsSection]

    var body: some View {
        ForEach(sections, id: \.id) { section in
            DescriptorSection(model: model, section: section)
        }
    }
}

/// One section: its rows, or the one state that explains why it has none.
struct DescriptorSection: View {
    @ObservedObject var model: SettingsModel
    let section: ManagementSettingsSection
    /// Rows this pane draws itself, by key. The Computer pane's app list is the
    /// one member: it is a pane-level choice of editor, never a second copy of
    /// the row's own definition.
    var specialised: (ManagementSettingRow) -> AnyView? = { _ in nil }

    var body: some View {
        Section(section.title) {
            DescriptorRows(model: model, section: section.id, specialised: specialised)
        }
    }
}

/// One section's rows, without the box around them, so a sheet can carry the
/// same rows the pane does.
struct DescriptorRows: View {
    @ObservedObject var model: SettingsModel
    let section: String
    var specialised: (ManagementSettingRow) -> AnyView? = { _ in nil }
    /// Keys this surface draws elsewhere. A key with two controls is two ways
    /// to answer one question, which is what the sheet and the list row were
    /// doing with a channel's enable toggle (M34 §5.2).
    var excluding: Set<String> = []

    var body: some View {
        switch model.section(section) {
        case .unread, .loading:
            ProgressView().controlSize(.small).accessibilityHidden(true)
        case .loaded(let rows):
            ForEach(rows.rows.filter { !excluding.contains($0.key) }, id: \.key) { row in
                body(for: row)
            }
        case .requiresNewerEngine:
            Text(model.newerEngineSentence)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
        case .unavailable(let sentence):
            Text(sentence)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
        }
    }

    @ViewBuilder
    private func body(for row: ManagementSettingRow) -> some View {
        if let view = specialised(row) {
            view
        } else {
            DescriptorRow(model: model, section: section, row: row)
        }
    }
}

/// The section ids a sub-page reads.
///
/// M34 §5.1 and §5.2 publish the shapes `providers.<id>` and `channels.<name>`,
/// so these read the contract's own ids rather than enumerating providers or
/// channels in Swift. Both are also what their pane filters on, so a section
/// that belongs to one sub-page is never drawn twice.
extension ManagementSettingsSection {
    public static let channelPrefix = "channels."
    public static let providerPrefix = "providers."

    public var channelName: String? {
        guard id.hasPrefix(Self.channelPrefix) else { return nil }

        return String(id.dropFirst(Self.channelPrefix.count))
    }

    public var providerId: String? {
        guard id.hasPrefix(Self.providerPrefix) else { return nil }

        return String(id.dropFirst(Self.providerPrefix.count))
    }
}
