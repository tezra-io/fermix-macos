import SwiftUI

/// The three native driver features the `Features` pill counts (decision D6).
///
/// They are not plugins: they are daemon settings whose switch lives in the pane
/// that owns them. So a row here says where it stands and opens that pane, and
/// draws no switch of its own — a second switch would need the descriptor key's
/// name written in Swift, which is the field inventory M34 §7.7 forbids.
public struct IntegrationFeature: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// Where the daemon says this feature stands, or nil where nothing has been
    /// read yet. Three-valued, because `Off` on an unread snapshot is a claim
    /// about a daemon nobody has asked, and it is indistinguishable on screen
    /// from a feature the operator actually turned off.
    public let enabled: Bool?
    /// The pane that owns this feature's switch.
    public let pane: SettingsPane

    public var status: String {
        guard let enabled else { return ProductStrings[.integrationFeatureUnread] }

        return ProductStrings[enabled ? .integrationFeatureOn : .integrationFeatureOff]
    }

    public var accessibilityLabel: String { ProductStrings.commaPair(title, status) }

    /// The page's own search rule, so typing under the Features pill filters
    /// exactly as it does under every other one.
    public func matches(_ query: String) -> Bool {
        IntegrationSearch.matches(query, title: title, summary: summary)
    }

    /// The three rows, from the daemon's own feature flags. An unread snapshot
    /// still draws all three: the pill's count is a property of this build, and
    /// a row that vanished while the daemon was being read would make the count
    /// move for a reason nobody could see.
    public static func rows(_ features: ManagementSetupFeatures?) -> [IntegrationFeature] {
        [
            IntegrationFeature(
                id: "computer_use",
                title: ProductStrings[.integrationFeatureComputerUse],
                summary: ProductStrings[.integrationFeatureComputerUseBody],
                enabled: features?.computerUse,
                pane: .computer
            ),
            IntegrationFeature(
                id: "computer_history",
                title: ProductStrings[.integrationFeatureComputerHistory],
                summary: ProductStrings[.integrationFeatureComputerHistoryBody],
                enabled: features?.computerHistory.enabled,
                pane: .computer
            ),
            IntegrationFeature(
                id: "meetings",
                title: ProductStrings[.integrationFeatureMeetings],
                summary: ProductStrings[.integrationFeatureMeetingsBody],
                enabled: features?.meetings,
                pane: .meetings
            )
        ]
    }
}

/// One Features row, in the same shape a plugin row takes: the mark, the name
/// over its description, where it stands, and the way to the pane that owns it.
struct IntegrationFeatureRow: View {
    let feature: IntegrationFeature
    let open: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            PluginMarkTile(name: feature.id, size: IntegrationMetrics.tileSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .fermixType(Typography.style(.callout).weight(.medium))
                    .foregroundStyle(Palette.ink.color)

                Text(feature.summary)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(feature.accessibilityLabel)

            Spacer(minLength: Spacing.s)

            Text(feature.status)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)

            Button(ProductStrings[.integrationOpen], action: open)
                .accessibilityLabel(
                    ProductStrings.commaPair(ProductStrings[.integrationOpen], feature.title)
                )
        }
        .padding(.vertical, Spacing.xs)
    }
}

/// The row's icon tile: a rounded square holding the plugin's own logo, or the
/// neutral symbol where the catalog publishes none (redlines §5.8, §8.4).
///
/// It is an icon rather than a container: the no-container rule is about boxes
/// drawn around content, and a mark needs a shape to sit in.
///
/// One lookup for both row kinds. The page draws registry plugins and the three
/// native driver features in one list and a row carries only its name, so the
/// name is read against the plugin roster and then the feature roster, in that
/// order.
struct PluginMarkTile: View {
    let name: String
    let size: Double

    var body: some View {
        VendorMarkView(mark: VendorMarks.integration(name), kind: .plugin, size: size)
    }
}
