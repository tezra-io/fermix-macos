import SwiftUI

/// The Pet sidebar destination: a live preview, the call controls, and the one
/// switch that opens the optional floating window.
///
/// Nothing here asks macOS for the microphone. Consent belongs to the first
/// voice start, which is the call button and nothing else.
struct PetSurfaceView: View {
    @ObservedObject var model: PetFeatureModel

    var body: some View {
        VStack(spacing: 0) {
            SurfaceTitlebar(title: ProductStrings[.sidebarPet])

            VStack(spacing: Spacing.m) {
                preview

                Text(model.statusText)
                    .fermixType(Typography.style(.callout).weight(.regular))
                    .foregroundStyle(Palette.secondary.color)
                    .accessibilityAddTraits(.updatesFrequently)

                controls

                Card {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Toggle(
                            model.floatingWindowActionTitle,
                            isOn: Binding(
                                get: { model.floatingWindowShown },
                                set: { model.setFloatingWindow($0) }
                            )
                        )
                        .toggleStyle(.switch)

                        Text(ProductStrings[.petWindowHint])
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.faint.color)
                    }
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 420)

                Text(ProductStrings[.petMicrophoneNotice])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.faint.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.top, Spacing.s)
        }
    }

    private var preview: some View {
        ZStack {
            Circle()
                .fill(Palette.chipFill.color)
                .frame(width: 132, height: 132)

            MascotArtwork(size: 108)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(model.accessibilityValue)
    }

    private var controls: some View {
        HStack(spacing: Spacing.s) {
            PrimaryAction(model.callActionTitle, size: .inWindow) { model.toggleCall() }

            Button(model.muteActionTitle) { model.toggleMute() }
                .buttonStyle(SecondaryButtonStyle(.inWindow))
                .disabled(!model.callActive)

            if model.showsInterrupt {
                Button(model.interruptActionTitle) { model.interrupt() }
                    .buttonStyle(SecondaryButtonStyle(.inWindow))
            }
        }
    }
}
