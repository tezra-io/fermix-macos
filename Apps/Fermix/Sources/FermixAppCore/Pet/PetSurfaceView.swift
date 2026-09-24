import SwiftUI

/// The Pet sidebar destination: a live preview, the call controls, and the one
/// switch that opens the optional floating window, on a grouped `Form`.
///
/// Nothing here asks macOS for the microphone. Consent belongs to the first
/// voice start, which is the call button and nothing else.
struct PetSurfaceView: View {
    @ObservedObject var model: PetFeatureModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: Spacing.m) {
                    preview

                    Text(model.statusText)
                        .fermixType(Typography.style(.callout).weight(.regular))
                        .foregroundStyle(Palette.secondary.color)
                        .accessibilityAddTraits(.updatesFrequently)

                    controls

                    if model.callActive {
                        liveCall
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.s)
            } footer: {
                // The footer of the section that holds the call button, which
                // is the control the sentence is about. On a section of its own
                // it drew a card around one line of explanatory text, which is
                // the shape a row uses and this is not a row.
                Text(ProductStrings[.petMicrophoneNotice])
            }

            Section {
                Toggle(
                    model.floatingWindowActionTitle,
                    isOn: Binding(
                        get: { model.floatingWindowShown },
                        set: { model.setFloatingWindow($0) }
                    )
                )
            } footer: {
                Text(ProductStrings[.petWindowHint])
            }
        }
        .formStyle(.grouped)
        .showsAmbientGround()
        .rowActions()
        .scrollIndicators(.never)
        .paneScrollEdges()
        .navigationTitle(ProductStrings[.sidebarPet])
    }

    private var preview: some View {
        PetMark()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityValue(model.accessibilityValue)
    }

    /// What a live call reports beside its controls: the last caption line, what
    /// the backend delegation is doing, and what the voice has cost so far.
    /// Each row is drawn only where the daemon has actually sent it, and the
    /// whole block only while a call is up.
    @ViewBuilder private var liveCall: some View {
        VStack(spacing: Spacing.xxs) {
            if let caption = model.captionLine {
                Text(caption)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if let task = model.taskStatusText {
                Text(task)
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.faint.color)
            }

            if let cost = model.voiceCostText {
                Text(cost)
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.faint.color)
            }

            if model.showsCancelTask {
                Button(model.cancelTaskActionTitle) { model.cancelTask() }
                    .buttonStyle(SecondaryButtonStyle(.inWindow))
            }
        }
        .frame(maxWidth: .infinity)
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
