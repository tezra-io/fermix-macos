import SwiftUI

/// Connect AI: the shell, not the forms.
///
/// M34 §5 keeps configuration daemon-served. Every row here opens the hosted
/// Setup, where the daemon owns the sign-in and the key handling; Swift parses
/// no provider, secret, or config value. The vendor marks are the recorded
/// official ones, or the vendor's text name beside a neutral symbol — never a
/// fabricated monogram.
struct ConnectAISurface: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeading(
                title: ProductStrings[.connectAITitle],
                subcopy: ProductStrings[.connectAISubcopy]
            )
            .padding(.bottom, 28)

            VStack(spacing: Spacing.s) {
                ProviderSignInRow(
                    mark: .chatGPT,
                    name: ProductStrings[.connectAIChatGPTName],
                    hint: ProductStrings[.connectAIChatGPTHint],
                    action: model.openHostedSetup
                )
                ProviderSignInRow(
                    mark: .claude,
                    name: ProductStrings[.connectAIClaudeName],
                    hint: ProductStrings[.connectAIClaudeHint],
                    action: model.openHostedSetup
                )
                APIKeyRow(action: model.openHostedSetup)
            }
            .frame(width: 460)

            LinkButton(title: ProductStrings[.connectAISkip], action: model.advance)
                .padding(.top, 22)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 110)
        .padding(.top, Spacing.xs)
        .task { await model.refreshReadiness() }
    }
}

/// Connect channel: Telegram as the hero, two alternates, and the pairing tile
/// that never draws a mock code.
struct ConnectChannelSurface: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeading(
                title: ProductStrings[.connectChannelTitle],
                subcopy: ProductStrings[.connectChannelSubcopy]
            )
            .padding(.bottom, 26)

            HStack(alignment: .top, spacing: 14) {
                TelegramHeroCard(action: model.openHostedSetup)

                VStack(spacing: 14) {
                    ChannelAlternateCard(
                        mark: .slack,
                        name: ProductStrings[.connectChannelSlackName],
                        hint: ProductStrings[.connectChannelSlackHint],
                        action: model.openHostedSetup
                    )
                    ChannelAlternateCard(
                        mark: .discord,
                        name: ProductStrings[.connectChannelDiscordName],
                        hint: ProductStrings[.connectChannelDiscordHint],
                        action: model.openHostedSetup
                    )
                }
                .frame(width: 240)
            }
            .frame(width: 620)

            if let blocked = model.blocked {
                Text(blocked.message)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .padding(.top, Spacing.s)
            }

            LinkButton(title: ProductStrings[.connectChannelSkip], action: model.advance)
                .padding(.top, 20)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 90)
        .padding(.top, Spacing.xs)
        .task { await model.refreshReadiness() }
    }
}

/// The title and subcopy every configure surface opens with.
struct SurfaceHeading: View {
    let title: String
    let subcopy: String

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Text(title)
                .fermixType(Typography.style(.title))
                .foregroundStyle(Palette.ink.color)

            Text(subcopy)
                .fermixType(Typography.style(.bodyCompact))
                .foregroundStyle(Palette.secondary.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One 64-point provider row: the mark, the name and hint, and the button that
/// hands off to the daemon-served Setup.
struct ProviderSignInRow: View {
    let mark: VendorMark
    let name: String
    let hint: String
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 14) {
            VendorMarkDisc(mark: mark, diameter: 36)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .fermixType(Typography.style(.body).weight(.semibold))
                    .foregroundStyle(Palette.ink.color)

                Text(hint)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.faint.color)
            }

            Spacer(minLength: Spacing.s)

            Button(action: action) {
                HStack(spacing: 6) {
                    Text(ProductStrings[.connectAISignIn])
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 12))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(SecondaryButtonStyle(.inWindow))
            .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.connectAISignIn], name))
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.cardFill.color))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(
                Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                lineWidth: Stroke.hairline
            )
        )
    }
}

/// The dashed 56-point row for an API key. Dashed because it is the quieter
/// path, not because it is unfinished.
struct APIKeyRow: View {
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "key")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(ProductStrings[.connectAIKeyRowTitle])
                        .fermixType(Typography.style(.bodyCompact).weight(.semibold))
                        .foregroundStyle(Palette.ink.color)

                    Text(ProductStrings[.connectAIKeyRowHint])
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.faint.color)
                }

                Spacer(minLength: Spacing.s)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.faint.color)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(
                Palette.hairline(.strong, increaseContrast: contrast == .increased).color,
                style: StrokeStyle(lineWidth: Stroke.hairline, dash: [4, 3])
            )
        )
        .accessibilityLabel(ProductStrings[.connectAIKeyRowTitle])
        .accessibilityHint(ProductStrings[.connectAIKeyRowHint])
    }
}

/// The Telegram hero: the accent border, the pairing tile, and one full-width
/// action.
struct TelegramHeroCard: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: Spacing.s) {
            ZStack {
                Circle().fill(Palette.accentWash.color)
                VendorMarkImage(mark: .telegram, size: 22)
            }
            .frame(width: 44, height: 44)

            Text(ProductStrings[.connectChannelTelegramName])
                .fermixType(Typography.style(.body).weight(.semibold))
                .foregroundStyle(Palette.ink.color)

            Text(ProductStrings[.connectChannelTelegramHint])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.faint.color)

            PairingTileView(tile: ChannelPairingTile(payload: nil))

            PrimaryAction(ProductStrings[.connectChannelTelegramCTA], size: .inWindow, action: action)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.cardFill.color))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.accent.color, lineWidth: Stroke.heroBorder)
        )
        .shadow(color: Palette.heroGlow.color, radius: 13, y: 8)
    }
}

/// The pairing tile. With no daemon payload it carries the truthful
/// instruction; the 92-point frame is kept for the real code.
struct PairingTileView: View {
    let tile: ChannelPairingTile

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: tile.rendersCode ? "qrcode" : "arrow.up.forward.square")
                .font(.system(size: 20))
                .foregroundStyle(Palette.faint.color)
                .accessibilityHidden(true)

            Text(tile.title)
                .fermixType(Typography.style(.caption))
                .foregroundStyle(Palette.faint.color)
                .multilineTextAlignment(.center)
        }
        .frame(width: ChannelPairingTile.size, height: ChannelPairingTile.size)
        .background(
            RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous)
                .fill(Palette.chipFill.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.controlCompact, style: .continuous).strokeBorder(
                Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                lineWidth: Stroke.hairline
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.title)
        .accessibilityValue(tile.instruction)
    }
}

/// One 240-point alternate channel card.
struct ChannelAlternateCard: View {
    let mark: VendorMark
    let name: String
    let hint: String
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                VendorMarkDisc(mark: mark, diameter: 36)

                Text(name)
                    .fermixType(Typography.style(.bodyCompact).weight(.semibold))
                    .foregroundStyle(Palette.ink.color)

                Text(hint)
                    .fermixType(Typography.style(.caption).weight(.regular))
                    .foregroundStyle(Palette.faint.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.m)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.cardFill.color))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(
                Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                lineWidth: Stroke.hairline
            )
        )
        .accessibilityLabel(name)
        .accessibilityHint(hint)
    }
}
