import SwiftUI

/// The words of a watcher's detail, from its published fields. Its purpose
/// and instructions are the owner's own words and are drawn as written;
/// nothing a watcher read is ever here.
public enum CueWatcherDetailWords {
    /// The filter: the Cues filter model it uses, the main model where none
    /// is chosen, or none. A filter kind this build does not know is not
    /// named at all: it draws no Filter row rather than a guess.
    public static func filter(_ watcher: ManagementCueWatcher) -> String? {
        switch watcher.filter {
        case .none: return ProductStrings[.cuesWatcherFilterNone]
        case .llm: return watcher.filterModel?.model ?? ProductStrings[.cuesWatcherFilterMainModel]
        case .unrecognized: return nil
        }
    }

    /// "Release watch · keeps no notes", and paused where it is.
    public static func task(_ watcher: ManagementCueWatcher) -> String {
        var parts = [
            watcher.task.name ?? watcher.task.jobId,
            ProductStrings[watcher.taskNotes ? .cuesWatcherKeepsNotes : .cuesWatcherKeepsNoNotes]
        ]
        if watcher.task.paused { parts.append(ProductStrings[.cuesWatcherPaused]) }

        return parts.dropFirst().reduce(parts[0]) { ProductStrings.middot($0, $1) }
    }

    public static func dailyLimit(_ watcher: ManagementCueWatcher) -> String {
        watcher.dailyCap == 0 ? ProductStrings[.cuesNone] : String(format: ProductStrings[.cuesWatcherItemsFormat], watcher.dailyCap)
    }

    /// The day's six counts, from what reached the watcher to what it did.
    public static func lastDay(_ counts: ManagementCueWatcher.Counts) -> String {
        let parts = [
            String(format: ProductStrings[.cuesWatcherOfferedFormat], counts.offered),
            String(format: ProductStrings[.cuesWatcherWaitingFormat], counts.waiting),
            String(format: ProductStrings[.cuesWatcherPassedFormat], counts.passed),
            String(format: ProductStrings[.cuesWatcherDroppedFormat], counts.dropped),
            String(format: ProductStrings[.cuesWatcherActedFormat], counts.acted),
            String(format: ProductStrings[.cuesWatcherFailedFormat], counts.failed)
        ]

        return parts.dropFirst().reduce(parts[0]) { ProductStrings.middot($0, $1) }
    }

    /// The examples, counted and never shown: an example holds a cue's
    /// snapshot.
    public static func examples(_ examples: ManagementCueWatcherDetail.Examples) -> String {
        ProductStrings.middot(
            String(format: ProductStrings[.cuesWatcherUsefulFormat], examples.pass),
            String(format: ProductStrings[.cuesWatcherNotUsefulFormat], examples.drop)
        )
    }

    /// The words to listen for, as the owner gave them.
    public static func listenFor(_ words: [String]) -> String {
        words.joined(separator: ", ")
    }

    /// One instruction, its number first.
    public static func instruction(_ instruction: ManagementCueWatcherDetail.Instruction) -> String {
        String(format: ProductStrings[.cuesWatcherInstructionFormat], instruction.number, instruction.text)
    }

    public static func added(_ instruction: ManagementCueWatcherDetail.Instruction) -> String? {
        ManagementCueTime.date(instruction.addedAt).map {
            String(format: ProductStrings[.cuesWatcherAddedFormat], CueTimes.day($0))
        }
    }
}

/// A watcher's detail, read-only (§4.4). Watchers are made and changed in a
/// chat with Fermix, and the page's one way there opens Chat with an empty
/// composer: the app never writes a message for the owner.
struct CuesWatcherPage: View {
    let name: String
    @ObservedObject var model: SettingsModel
    let done: () -> Void

    private var detail: ManagementCueWatcherDetail? { model.cueWatcherDetails[name]?.value }
    private var watcher: ManagementCueWatcher? { detail?.row ?? model.cueWatcher(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let watcher {
                heading(watcher)
                CuesPageForm { facts(watcher) }
            } else if case .unavailable(let sentence) = model.cueWatcherDetails[name] {
                CueNote(text: sentence, attention: true)
            } else {
                CueNote(text: ProductStrings[.cuesWatcherGone])
            }

            footer
        }
        .task { await model.readCueWatcher(name) }
    }

    private func heading(_ watcher: ManagementCueWatcher) -> some View {
        CuesPageHeading(
            title: watcher.name,
            status: watcher.statusSentence,
            tone: CueTone.watcher(watcher),
            attention: watcher.state.drawsAttention
        ) {
            VendorMarkView(symbol: CueWatcherProjection.symbol, size: IntegrationMetrics.tileSize)
        } trailing: {
            EmptyView()
        }
    }

    /// The owner's own words first, set at the reading edge, then what the
    /// watcher runs on and did.
    @ViewBuilder
    private func facts(_ watcher: ManagementCueWatcher) -> some View {
        if let detail, detail.purpose != nil || !detail.listenFor.isEmpty || !detail.instructions.isEmpty {
            Section {
                if let purpose = detail.purpose {
                    CuesStackedFact(label: ProductStrings[.cuesWatcherPurpose], text: purpose)
                }
                if !detail.listenFor.isEmpty {
                    CuesStackedFact(label: ProductStrings[.cuesWatcherListenFor], text: CueWatcherDetailWords.listenFor(detail.listenFor))
                }
                if !detail.instructions.isEmpty {
                    instructionRows(detail.instructions)
                }
            }
        }

        Section {
            if let filter = CueWatcherDetailWords.filter(watcher) {
                LabeledContent(ProductStrings[.cuesWatcherFilter]) { CueValue(text: filter) }
            }
            LabeledContent(ProductStrings[.cuesWatcherSources]) {
                CueValue(text: watcher.sources.isEmpty ? ProductStrings[.cuesNone] : watcher.sources.joined(separator: ", "))
            }
            LabeledContent(ProductStrings[.cuesWatcherTask]) { CueValue(text: CueWatcherDetailWords.task(watcher)) }
            LabeledContent(ProductStrings[.cuesWatcherDailyLimit]) { CueValue(text: CueWatcherDetailWords.dailyLimit(watcher)) }
            LabeledContent(ProductStrings[.cuesWatcherLastDay]) { CueValue(text: CueWatcherDetailWords.lastDay(watcher.counts)) }

            if let examples = detail?.examples {
                LabeledContent(ProductStrings[.cuesWatcherExamples]) { CueValue(text: CueWatcherDetailWords.examples(examples)) }
            }
        }
    }

    /// Each instruction on its own line, numbered, with the day it was added
    /// beside it.
    private func instructionRows(_ instructions: [ManagementCueWatcherDetail.Instruction]) -> some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
            Text(ProductStrings[.cuesWatcherInstructions])

            ForEach(instructions, id: \.number) { instruction in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(CueWatcherDetailWords.instruction(instruction))
                        .foregroundStyle(Palette.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let added = CueWatcherDetailWords.added(instruction) {
                        Text(added)
                            .fermixType(Typography.style(.caption))
                            .foregroundStyle(Palette.faint.color)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.s) {
            CueNote(text: ProductStrings[.cuesWatchersFooter])
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(ProductStrings[.cuesWatchersOpenChat], action: openChat)
                .buttonStyle(SecondaryButtonStyle(.row))

            PrimaryAction(ProductStrings[.settingsSheetDone], size: .row, action: done)
        }
    }

    /// Chat, with nothing written into its composer.
    private func openChat() {
        done()
        model.showChat(at: nil)
    }
}
