import SwiftUI
import UniformTypeIdentifiers

/// Logs: a bounded page of daemon-owned entries, a filter bar, and the four
/// actions the surface owns.
///
/// The poll runs only while this view is on screen and not paused, which is
/// exactly what `pollingActive` says, and the timer asks the model rather than
/// deciding for itself.
struct LogsView: View {
    @ObservedObject var model: LogsModel

    @State private var exporting = false

    var body: some View {
        VStack(spacing: 0) {
            SurfaceTitlebar(title: ProductStrings[.logsTitle])

            controls

            statusLine

            entries
        }
        .task {
            model.setVisible(true)
            await model.refresh()
        }
        .onDisappear { model.setVisible(false) }
        .modifier(LogsPolling(model: model))
        .fileExporter(
            isPresented: $exporting,
            document: LogsDocument(text: model.copyVisible()),
            contentType: .plainText,
            defaultFilename: ProductStrings[.logsExportFilename]
        ) { _ in }
    }

    private var controls: some View {
        HStack(spacing: Spacing.xs) {
            TextField(ProductStrings[.logsSearchPlaceholder], text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { Task { await model.applyFilters() } }

            Picker(ProductStrings[.logsLevelLabel], selection: levelBinding) {
                Text(ProductStrings[.logsLevelAll]).tag("")
                ForEach(LogsView.filterableLevels, id: \.self) { level in
                    Text(level).tag(level)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Button(model.pauseActionTitle) { model.togglePause() }
                .buttonStyle(SecondaryButtonStyle(.inWindow))

            Button(ProductStrings[.logsCopy]) { Clipboard.write(model.copyVisible()) }
                .buttonStyle(SecondaryButtonStyle(.inWindow))
                .disabled(model.entries.isEmpty)

            Button(ProductStrings[.logsExport]) { exporting = true }
                .buttonStyle(SecondaryButtonStyle(.inWindow))
                .disabled(model.entries.isEmpty)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, Spacing.s)
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

    @ViewBuilder
    private var statusLine: some View {
        if let message = LogsView.message(for: model.status) {
            Text(message)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.warning.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.bottom, Spacing.xs)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    @ViewBuilder
    private var entries: some View {
        if model.entries.isEmpty {
            Card { EmptyState(model: model.emptyState) }
                .padding(.horizontal, 26)
                .padding(.bottom, 22)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                        LogRow(entry: entry)
                    }

                    if model.canLoadOlder {
                        Button(ProductStrings[.logsLoadOlder]) { Task { await model.loadOlder() } }
                            .buttonStyle(SecondaryButtonStyle(.inWindow))
                            .padding(.top, Spacing.xs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.bottom, 22)
            }
        }
    }

    /// The levels worth filtering on, by wire value. `emergency` and `alert`
    /// exist on the wire but the engine does not emit them, so offering them
    /// would be a filter that always returns nothing.
    static let filterableLevels: [String] = [
        ManagementLogLevel.error,
        .warning,
        .notice,
        .info,
        .debug
    ].map(\.wireValue)

    static func message(for status: LogsStatus) -> String? {
        switch status {
        case .idle: return nil
        case .truncated(let message), .reset(let message), .refused(let message), .failed(let message):
            return message
        }
    }
}

/// One log line, in the mono ramp, with the level tinted.
struct LogRow: View {
    let entry: ManagementLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(entry.time)
                .foregroundStyle(Palette.faint.color)

            Text(entry.level.wireValue)
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
        .accessibilityValue(entry.level.wireValue)
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
