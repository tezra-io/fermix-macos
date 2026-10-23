import SwiftUI

/// The words of a watcher's detail, from its published fields. Its purpose
/// and instructions are the owner's own words and are drawn as written;
/// nothing a watcher read is ever here.
public enum CueWatcherDetailWords {
    /// The filter: its own model, the default filter model, or none. A
    /// filter kind this build does not know is not named at all: it draws no
    /// Filter row rather than a guess.
    public static func filter(_ watcher: ManagementCueWatcher) -> String? {
        if let own = watcher.filterModel { return own.model }

        switch watcher.filter {
        case .none: return ProductStrings[.cuesWatcherFilterNone]
        case .llm: return ProductStrings[.cuesWatcherFilterDefault]
        case .unrecognized: return nil
        }
    }

    /// "Release watch · runs on cues · keeps no notes", and paused where it is.
    public static func task(_ watcher: ManagementCueWatcher) -> String {
        var parts = [
            watcher.task.name ?? watcher.task.jobId,
            ProductStrings[.cuesWatcherRunsOnCues],
            ProductStrings[watcher.taskNotes ? .cuesWatcherKeepsNotes : .cuesWatcherKeepsNoNotes]
        ]
        if watcher.task.paused { parts.append(ProductStrings[.cuesWatcherPaused]) }

        return parts.dropFirst().reduce(parts[0]) { ProductStrings.middot($0, $1) }
    }

    public static func dailyLimit(_ watcher: ManagementCueWatcher) -> String {
        watcher.dailyCap == 0 ? ProductStrings[.cuesNone] : String(format: ProductStrings[.cuesWatcherItemsFormat], watcher.dailyCap)
    }

    /// The day's five counts.
    public static func lastDay(_ counts: ManagementCueWatcher.Counts) -> String {
        let parts = [
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
        VStack(alignment: .leading, spacing: 2) {
            Text(watcher.name)
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)
            CueNote(text: watcher.statusSentence, attention: watcher.state.drawsAttention)
        }
    }

    @ViewBuilder
    private func facts(_ watcher: ManagementCueWatcher) -> some View {
        if let purpose = detail?.purpose {
            LabeledContent(ProductStrings[.cuesWatcherPurpose]) { CueValue(text: purpose) }
        }
        if let instructions = detail?.instructions, !instructions.isEmpty {
            LabeledContent(ProductStrings[.cuesWatcherInstructions]) {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(instructions, id: \.number) { instruction in
                        CueValue(text: CueWatcherDetailWords.instruction(instruction))
                        if let added = CueWatcherDetailWords.added(instruction) {
                            CueNote(text: added)
                        }
                    }
                }
            }
        }

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
