import SwiftUI
import UniformTypeIdentifiers

/// Doctor: the summary banner and one grouped list of checks (M34 §3.2).
///
/// The right rail is gone: the network run and the two support actions live in
/// the toolbar, and each failed row carries the daemon's remediation title with
/// its one action. Every answer comes from the running daemon, and the banner
/// says so.
struct DoctorView: View {
    @ObservedObject var model: DoctorModel
    let router: any CommandPerforming

    var body: some View {
        Form {
            banner
            checkList
        }
        .formStyle(.grouped)
        .navigationTitle(ProductStrings[.doctorTitle])
        .toolbar {
            SurfaceToolbar(
                spec: CommandTable.toolbar(for: .doctor),
                router: router,
                statusText: model.isRunning ? ProductStrings[.doctorRunning] : nil
            )
        }
        .task { await model.runLocal() }
        .fileExporter(
            isPresented: Binding(
                get: { model.pendingBundle != nil },
                set: { if !$0 { model.clearPendingBundle() } }
            ),
            document: DiagnosticsDocument(data: model.pendingBundle ?? Data()),
            contentType: .json,
            defaultFilename: ProductStrings[.doctorSupportExportFilename]
        ) { _ in model.clearPendingBundle() }
    }

    @ViewBuilder
    private var banner: some View {
        if model.uninstallNoticeShown {
            Section {
                LabeledContent(ProductStrings[.uninstallTitle]) {
                    Button(ProductStrings[.uninstallReveal]) { model.revealSettingsFile() }
                }

                Text(ProductStrings[.uninstallBody])
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let banner = model.banner {
            Section {
                DoctorBannerView(banner: banner, running: model.isRunning, cancel: { Task { await model.cancel() } })
            }
        } else if case .failed(let message) = model.phase {
            Section {
                SurfaceFailure(
                    message: message,
                    actionTitle: ProductStrings[.doctorRetry],
                    action: { Task { await model.runLocal() } }
                )
                .frame(height: 100)
            }
        }

        if let message = model.supportMessage {
            Section {
                Text(message)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.warning.color)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    @ViewBuilder
    private var checkList: some View {
        Section(ProductStrings[.sectionHeaderChecks]) {
            if model.rows.isEmpty {
                EmptyState(
                    model: EmptyStateModel(
                        message: ProductStrings[model.isRunning ? .doctorRunning : .doctorNoChecks]
                    )
                )
            } else {
                ForEach(model.rows) { row in
                    DoctorCheckRow(row: row) { model.perform($0) }
                }
            }
        }
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

/// The summary banner: what the run found, where the answers came from, and
/// Cancel while a run is live.
struct DoctorBannerView: View {
    let banner: DoctorBanner
    let running: Bool
    let cancel: () -> Void

    var body: some View {
        LabeledContent {
            if running {
                Button(ProductStrings[.doctorCancel], action: cancel)
            } else {
                Text(banner.checkedLabel)
                    .fermixType(Typography.style(.caption))
                    .foregroundStyle(Palette.faint.color)
            }
        } label: {
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
}

/// One check row: the status disc, the check's name over the daemon's summary,
/// the remediation where there is something to fix, and the one action.
///
/// The disc is the row's one visual status indicator; the state itself is
/// words, carried by the accessibility value, so it never depends on colour.
struct DoctorCheckRow: View {
    let row: DoctorRowModel
    let perform: (DoctorRowAction) -> Void

    var body: some View {
        LabeledContent {
            // The title comes from the action itself, so the button cannot be
            // drawn without one.
            if let action = row.action {
                Button(action.title) { perform(action) }
            }
        } label: {
            HStack(alignment: .top, spacing: Spacing.s) {
                statusDisc

                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .fermixType(Typography.style(.callout).weight(.medium))
                        .foregroundStyle(Palette.ink.color)
                        .lineLimit(1)

                    // The summary wraps rather than losing its tail: it is the
                    // finding, and an ellipsis hides the part that names what
                    // to do.
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.secondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Remediation is what to do about it, and a healthy row has
                    // nothing to remediate. It reads under the finding rather
                    // than over it: drawn the brighter of the two, the hint
                    // looked like the check's own result and the result read as
                    // an aside. A remediation code is never drawn: `Remedy:
                    // daemon_socket.warning` is a wire token under a
                    // user-facing label (M34 §5.8).
                    if row.badge.tone != .pass, let title = row.remediationTitle {
                        Text(title)
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.faint.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if row.badge.tone != .pass, let body = row.remediationBody, !body.isEmpty {
                        Text(body)
                            .fermixType(Typography.style(.calloutSmall))
                            .foregroundStyle(Palette.faint.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Spacing.s)

                statusPill
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
    }

    /// The status disc: one glyph per tone, so a failed row is never drawn like
    /// a warning under a banner that says a check failed (redlines §5.9).
    private var statusDisc: some View {
        Circle()
            .fill(row.badge.tone.pillFill.color)
            .frame(width: 20, height: 20)
            .overlay(
                Image(systemName: row.badge.tone.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(row.badge.tone.textColor.color)
            )
            .accessibilityHidden(true)
    }

    /// The trailing letter pill of redlines §5.9: text only, no flood fill, so
    /// the state is words on every row and never colour alone.
    private var statusPill: some View {
        Text(row.badge.letters)
            .fermixType(Typography.style(.caption).weight(.semibold).uppercased())
            .foregroundStyle(row.badge.tone.textColor.color)
            .accessibilityHidden(true)
    }
}
