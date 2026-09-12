import SwiftUI
import UniformTypeIdentifiers

/// Logs: a bounded page of daemon-owned entries, running edge to edge, with
/// search, level, pause and export in the toolbar (M34 §3.2).
///
/// The poll runs only while this view is on screen and not paused, which is
/// exactly what `pollingActive` says, and the timer asks the model rather than
/// deciding for itself.
struct LogsView: View {
    @ObservedObject var model: LogsModel
    let router: any CommandPerforming

    var body: some View {
        entries
            .navigationTitle(ProductStrings[.logsTitle])
            .searchable(text: $model.search, prompt: ProductStrings[.logsSearchPlaceholder])
            .onSubmit(of: .search) { Task { await model.applyFilters() } }
            .toolbar { LogsToolbar(model: model, router: router) }
            .task {
                model.setVisible(true)
                await model.refresh()
            }
            .onDisappear { model.setVisible(false) }
            .modifier(LogsPolling(model: model))
            .fileExporter(
                isPresented: $model.exportRequested,
                document: LogsDocument(text: model.copyVisible()),
                contentType: .plainText,
                defaultFilename: ProductStrings[.logsExportFilename]
            ) { _ in }
    }

    @ViewBuilder
    private var entries: some View {
        if model.entries.isEmpty {
            SurfaceEmptyState(
                model: EmptyStateModel(message: statusMessage ?? model.emptyState.message),
                symbol: "text.append"
            )
        } else {
            List {
                if let message = statusMessage {
                    Text(message)
                        .fermixType(Typography.style(.calloutSmall))
                        .foregroundStyle(Palette.warning.color)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                    LogRow(entry: entry)
                }

                if model.canLoadOlder {
                    Button(ProductStrings[.logsLoadOlder]) { Task { await model.loadOlder() } }
                }
            }
            // M34 §3.2 and redlines §5.7: the log list runs edge to edge, which
            // is the plain style. The inset style is the shape they replaced.
            .listStyle(.plain)
        }
    }

    private var statusMessage: String? {
        LogsView.message(for: model.status)
    }

    /// The levels worth filtering on. `emergency` and `alert` exist on the
    /// wire but the engine does not emit them, so offering them would be a
    /// filter that always returns nothing.
    static let filterableLevels: [ManagementLogLevel] = [.error, .warning, .notice, .info, .debug]

    static func message(for status: LogsStatus) -> String? {
        switch status {
        case .idle: return nil
        case .truncated(let message), .reset(let message), .refused(let message), .failed(let message):
            return message
        }
    }
}

/// The level picker plus the command groups. The picker is a control rather
/// than a command, so it is declared here and the rest comes from the table.
struct LogsToolbar: ToolbarContent {
    @ObservedObject var model: LogsModel
    let router: any CommandPerforming

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker(ProductStrings[.logsLevelLabel], selection: levelBinding) {
                Text(ProductStrings[.logsLevelAll]).tag("")
                ForEach(LogsView.filterableLevels, id: \.wireValue) { level in
                    Text(LogLine.level(level)).tag(level.wireValue)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .accessibilityLabel(ProductStrings[.logsLevelLabel])
        }

        SurfaceToolbar(spec: CommandTable.toolbar(for: .logs), router: router)
    }

    /// The picker selects on the wire value, because the level vocabulary is a
    /// contract type and giving it a `Hashable` conformance for a control's
    /// convenience would put a UI requirement on the protocol layer.
    private var levelBinding: Binding<String> {
        Binding(
            get: { model.minimumLevel?.wireValue ?? "" },
            set: { newValue in
                model.minimumLevel = newValue.isEmpty ? nil : ManagementLogLevel(wireValue: newValue)
                Task { await model.applyFilters() }
            }
        )
    }
}

/// How a log line reads, as against how it arrives on the wire.
///
/// Both halves are the surface's, not the protocol's: `ManagementLogLevel` is a
/// contract type, and giving it a display title would put a window's
/// vocabulary on the wire layer.
enum LogLine {
    /// The daemon's ISO timestamp, in this Mac's own zone and format.
    ///
    /// The wire carries UTC with microseconds (`2026-08-19T12:00:00.512431+00:00`),
    /// which is the engine's format and not a time anybody reads. Console shows
    /// a localised time to the millisecond and so does this. A string the
    /// parser refuses is shown exactly as the daemon sent it: it is the only
    /// thing known about that row's time, and dropping it would lose it.
    static func time(_ wire: String) -> String {
        guard let moment = try? Self.wireTime.parse(wire) else { return wire }

        return moment.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
    }

    /// The level word, from the catalogue. The wire value is the key that
    /// selects it and is never the label.
    static func level(_ level: ManagementLogLevel) -> String {
        switch level {
        case .emergency: return ProductStrings[.logsLevelEmergency]
        case .alert: return ProductStrings[.logsLevelAlert]
        case .critical: return ProductStrings[.logsLevelCritical]
        case .error: return ProductStrings[.logsLevelError]
        case .warning: return ProductStrings[.logsLevelWarning]
        case .notice: return ProductStrings[.logsLevelNotice]
        case .info: return ProductStrings[.logsLevelInfo]
        case .debug: return ProductStrings[.logsLevelDebug]
        // A level this build has no word for. The daemon's own value is what
        // the operator can search the engine for.
        case .unrecognized(let value): return value
        }
    }

    /// The engine's own timestamp format, with the offset colon it writes and
    /// tolerant of a row that carries no fractional seconds.
    private static let wireTime = Date.ISO8601FormatStyle(
        timeZoneSeparator: .colon,
        includingFractionalSeconds: true
    )
}

/// One log line, in the mono ramp, with the level tinted.
struct LogRow: View {
    let entry: ManagementLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(LogLine.time(entry.time))
                .foregroundStyle(Palette.faint.color)

            Text(LogLine.level(entry.level))
                .foregroundStyle(tone.color)
                .frame(width: 56, alignment: .leading)

            Text(entry.message)
                .foregroundStyle(Palette.secondary.color)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .fermixType(Typography.style(.monoLog))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.message)
        .accessibilityValue(LogLine.level(entry.level))
    }

    private var tone: ThemedColor {
        switch entry.level {
        case .emergency, .alert, .critical, .error: return Palette.error
        case .warning: return Palette.warning
        case .notice, .info, .debug, .unrecognized: return Palette.faint
        }
    }
}

/// The two-second poll, which asks the model whether it may run at all.
private struct LogsPolling: ViewModifier {
    @ObservedObject var model: LogsModel

    func body(content: Content) -> some View {
        content.task(id: model.pollingActive) {
            guard model.pollingActive else { return }

            // A bounded sleep per tick rather than a retained timer: the task is
            // cancelled with the view, so nothing can poll a surface that is
            // gone.
            while !Task.isCancelled, model.pollingActive {
                try? await Task.sleep(nanoseconds: UInt64(LogsPolicy.pollInterval * 1_000_000_000))
                await model.poll()
            }
        }
    }
}

/// The exported file: exactly the visible entries, never a log file.
struct LogsDocument: FileDocument {
    static let readableContentTypes = [UTType.plainText]

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
