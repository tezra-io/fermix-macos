import SwiftUI

/// The panel under the status item: the redline's 300-point popover, its header
/// of facts, and three groups of rows separated by hairlines.
struct MenuBarPanel: View {
    let model: MenuPanelModel
    let perform: (MenuAction) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GlassChrome(.popover) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)

                Divider()
                    .overlay(hairline)

                VStack(spacing: 0) {
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 {
                            Divider()
                                .overlay(hairline)
                                .padding(.vertical, Spacing.xxs)
                                .padding(.horizontal, 6)
                        }

                        ForEach(group.rows) { row in
                            MenuRow(
                                title: row.title,
                                hint: row.hint,
                                shortcut: row.shortcut.map { KeyEquivalent($0) }
                            ) {
                                perform(row.action)
                            }
                        }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: WindowMetrics.popoverWidth)
        .fermixWindowEntrance()
    }

    private var header: some View {
        HStack(spacing: 10) {
            mascot

            VStack(alignment: .leading, spacing: 2) {
                Text(ProductStrings[.menuTitle])
                    .fermixType(Typography.style(.callout).weight(.semibold))
                    .foregroundStyle(Palette.ink.color)

                HStack(spacing: 6) {
                    Circle()
                        .fill(model.glyph == .running ? Palette.success.color : Palette.warning.color)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)

                    Text(model.statusLine)
                        .fermixType(Typography.style(.caption).weight(.regular))
                        .foregroundStyle(Palette.secondary.color)
                }
            }

            Spacer(minLength: Spacing.xs)

            Text(model.version)
                .fermixType(Typography.style(.caption).weight(.regular))
                .foregroundStyle(Palette.faint.color)
                .accessibilityLabel(String(format: ProductStrings[.menuVersionFormat], model.version))
        }
        .accessibilityElement(children: .combine)
    }

    /// The mascot, at the header's 28 points. It is decorative: the header's
    /// words carry the state.
    @ViewBuilder
    private var mascot: some View {
        if let image = PetAssetCache.shared.image(PetExpression.idle.layerAssetName(.body)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } else {
            FermixBoltShape()
                .fill(Palette.accent.color)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    private var hairline: Color {
        Palette.hairline(.faint, increaseContrast: contrast == .increased).color
    }
}
