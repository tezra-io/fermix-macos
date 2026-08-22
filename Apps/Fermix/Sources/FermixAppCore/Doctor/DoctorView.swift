import SwiftUI
import UniformTypeIdentifiers

/// Doctor: the summary banner, the check list, and the right rail.
///
/// Every answer comes from the running daemon, and the banner says so. The
/// network scope is behind an explicit button that states what it costs.
struct DoctorView: View {
    @ObservedObject var model: DoctorModel

    @State private var bundle: Data?

    var body: some View {
        VStack(spacing: 0) {
            SurfaceTitlebar(title: ProductStrings[.doctorTitle])

            HStack(alignment: .top, spacing: Spacing.s) {
                VStack(spacing: 14) {
                    banner
                    checkList
                }

                rail
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 22)
            .padding(.top, 6)
        }
        .task { await model.runLocal() }
        .fileExporter(
            isPresented: Binding(get: { bundle != nil }, set: { if !$0 { bundle = nil } }),
            document: DiagnosticsDocument(data: bundle ?? Data()),
            contentType: .json,
            defaultFilename: ProductStrings[.doctorSupportExportFilename]
        ) { _ in bundle = nil }
    }

    @ViewBuilder
    private var banner: some View {
        if let banner = model.banner {
            DoctorBannerView(banner: banner, running: model.isRunning, cancel: { Task { await model.cancel() } })
        } else if case .failed(let message) = model.phase {
            SurfaceFailure(
                message: message,
                actionTitle: ProductStrings[.doctorRetry],
                action: { Task { await model.runLocal() } }
            )
            .frame(height: 120)
        }
    }

    @ViewBuilder
    private var checkList: some View {
        if model.rows.isEmpty {
            Card {
                if model.isRunning {
                    LoadingSurface(message: ProductStrings[.doctorRunning]).frame(height: 200)
                } else {
                    EmptyState(model: EmptyStateModel(message: ProductStrings[.doctorNoChecks]))
                }
            }
        } else {
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().overlay(Palette.hairline(.faint).color)
                        }

                        DoctorCheckRow(row: row)
                    }
                }
            }
        }
    }

    private var rail: some View {
        VStack(spacing: Spacing.s) {
            SectionCard(label: ProductStrings[.doctorNetworkLabel]) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(ProductStrings[.doctorNetworkBody])
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)

                    Button(model.networkActionTitle) {
                        Task { await model.runNetwork() }
                    }
                    .buttonStyle(SecondaryButtonStyle(.inWindow))
                    .disabled(model.isRunning)
                }
                .padding(Spacing.m)
            }

            SectionCard(label: ProductStrings[.doctorSupportLabel]) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(ProductStrings[.doctorSupportExportHint])
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.secondary.color)

                    LinkButton(title: ProductStrings[.doctorSupportExport]) {
                        Task { bundle = await model.exportSupportBundle() }
                    }
                    .disabled(model.exporting)

                    LinkButton(title: ProductStrings[.doctorSupportOpenLogFolder]) {
                        model.openLogFolder()
                    }

                    if let message = model.supportMessage {
                        Text(message)
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.warning.color)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .padding(Spacing.m)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 250)
    }
}

/// The exported support bundle: exactly the bytes the daemon produced.
struct DiagnosticsDocument: FileDocument {
    static let readableContentTypes = [UTType.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The state-tinted summary banner, and Cancel while a run is live.
struct DoctorBannerView: View {
    let banner: DoctorBanner
    let running: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(banner.tone.textColor.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .fermixType(Typography.style(.bodyCompact).weight(.semibold))
                    .foregroundStyle(Palette.ink.color)

                Text(banner.explainer)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
            }

            Spacer(minLength: Spacing.s)

            if running {
                Button(ProductStrings[.doctorCancel], action: cancel)
                    .buttonStyle(SecondaryButtonStyle(.inWindow))
            } else {
                Text(banner.checkedLabel)
                    .fermixType(Typography.style(.monoLog))
                    .foregroundStyle(Palette.faint.color)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(fill.color))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(border.color, lineWidth: Stroke.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banner.title)
    }

    private var symbol: String {
        switch banner.tone {
        case .pass: return "checkmark.seal"
        case .warn: return "exclamationmark.triangle"
        case .fail: return "xmark.octagon"
        case .neutral: return "info.circle"
        }
    }

    private var fill: ThemedColor {
        switch banner.tone {
        case .pass: return Palette.successPillFill
        case .warn: return Palette.warnPillFill
        case .fail: return Palette.errorDiscFill
        case .neutral: return Palette.chipFill
        }
    }

    private var border: ThemedColor {
        switch banner.tone {
        case .pass: return Palette.successPillBorder
        case .warn: return Palette.warnPillBorder
        case .fail: return Palette.errorDiscBorder
        case .neutral: return Palette.hairline(.standard)
        }
    }
}

/// One 46-point check row: the status disc, the label, the fix hint, and the
/// letter pill. The pill is text only, so the status never depends on colour.
struct DoctorCheckRow: View {
    let row: DoctorRowModel

    var body: some View {
        HStack(spacing: Spacing.s) {
            statusDisc

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .fermixType(Typography.style(.callout).weight(.medium))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)

                if let fixHint = row.fixHint {
                    Text(fixHint)
                        .fermixType(Typography.style(.monoLog))
                        .foregroundStyle(Palette.secondary.color)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.s)

            LetterPill(badge: row.badge)
        }
        .padding(.horizontal, 18)
        .frame(height: 46)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
    }

    private var statusDisc: some View {
        Circle()
            .fill(row.badge.tone == .pass ? Palette.successPillFill.color : Palette.warnIconFill.color)
            .frame(width: 20, height: 20)
            .overlay(
                Image(systemName: row.badge.tone == .pass ? "checkmark" : "exclamationmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(row.badge.tone.textColor.color)
            )
            .accessibilityHidden(true)
    }
}
