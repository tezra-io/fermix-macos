import SwiftUI

/// The commands that answer a gap Fermix cannot answer itself (M34 §15.2).
///
/// One value, one sheet, both doors: Home's Attention row and Doctor's
/// `instructions` remediation open the same lines. The app runs none of them —
/// removing another product's launchd job is the operator's to do — so what it
/// owes is the exact command and one way to put it on the pasteboard.
public struct CoexistenceInstructions: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    /// The lines to run, in order. Never empty: a sheet with nothing to run
    /// would be the dead end this exists to close.
    public let commands: [String]

    public init(id: String, title: String, body: String, commands: [String]) {
        precondition(!id.isEmpty, "instructions are identified")
        precondition(!commands.isEmpty, "instructions carry at least one command")

        self.id = id
        self.title = title
        self.body = body
        self.commands = commands
    }
}

/// Which removal commands the legacy service unit needs on this Mac.
///
/// Two declared configurations along each of two axes, never a fallback chain
/// between them (M34 §15.2): the unit's own scope decides whether administrator
/// rights are needed, and whether a verb-capable `fermix` is on PATH decides
/// whether the line is the verb or the two raw launchd commands it wraps. The
/// answer to the second is `CLILinkPlanner`'s, which the app already computes;
/// nothing here runs a verb to find out.
extension CoexistenceInstructions {
    /// The engine's own catalogue entry id, which is what a Doctor remediation
    /// names in its `instructions` target.
    public static let legacyServiceUnitRemoval = "legacy_service_unit.removal"

    /// The unit's launchd label, mirrored from `Fermix.CLI.Service`.
    public static let legacyServiceLabel = "io.tezra.fermix"

    public static func legacyServiceUnit(
        scope: LegacyServiceScope,
        path: String,
        cli: CLILinkPlan
    ) -> CoexistenceInstructions {
        CoexistenceInstructions(
            id: legacyServiceUnitRemoval,
            title: ProductStrings[.coexistenceLegacyServiceTitle],
            body: ProductStrings[.coexistenceLegacyServiceBody],
            commands: legacyServiceCommands(scope: scope, path: path, cli: cli)
        )
    }

    /// The instructions for the unit the daemon reported, where it reported one.
    ///
    /// Both facts are read rather than composed: the daemon owns the home, so
    /// its scope and its path are the answer even where this app's own account
    /// would look somewhere else. A unit with no scope or no path carries no
    /// sheet, because the commands are the scope's and the path is one of them.
    public static func legacyServiceUnit(
        unit: ManagementLegacyServiceUnit?,
        cli: CLILinkPlan
    ) -> CoexistenceInstructions? {
        guard let unit, unit.present, let path = unit.path, !path.isEmpty else { return nil }

        switch unit.scope {
        case .user: return legacyServiceUnit(scope: .user, path: path, cli: cli)
        case .system: return legacyServiceUnit(scope: .system, path: path, cli: cli)
        case .none, .unrecognized: return nil
        }
    }

    private static func legacyServiceCommands(
        scope: LegacyServiceScope,
        path: String,
        cli: CLILinkPlan
    ) -> [String] {
        guard cli.offersVerb else { return rawCommands(scope: scope, path: path) }

        switch scope {
        case .user: return ["fermix service uninstall"]
        case .system: return ["sudo fermix service uninstall --system"]
        }
    }

    /// What to run where no `fermix` on PATH can run a verb, which is the state
    /// a DMG install is in until the launcher is linked.
    private static func rawCommands(scope: LegacyServiceScope, path: String) -> [String] {
        switch scope {
        case .user:
            return ["launchctl bootout gui/$UID/\(legacyServiceLabel)", "rm \(path)"]
        case .system:
            return ["sudo launchctl bootout system/\(legacyServiceLabel)", "sudo rm \(path)"]
        }
    }
}

extension CLILinkPlan {
    /// Whether a `fermix` that can run a verb is already on PATH, which is what
    /// decides between the verb and the raw launchd lines (M34 §15.2).
    public var offersVerb: Bool {
        switch self {
        case .linkedByThisApp, .ownedByHomebrew:
            return true
        case .foreignFileInPlace, .launcherMissing, .available:
            return false
        }
    }
}

/// The `fermix` command for Terminal, as the same sheet (M34 §4).
///
/// The assistant's Ready row is one door and the Help menu is the other; both
/// print the planner's own command and neither runs it, because linking into a
/// folder every account shares asks for a password the app does not take.
extension CoexistenceInstructions {
    public static let commandLineLink = "cli.link"

    public static func commandLine(_ plan: CLILinkPlan) -> CoexistenceInstructions? {
        guard case .available(let command, _) = plan else { return nil }

        return CoexistenceInstructions(
            id: commandLineLink,
            title: ProductStrings[.readyCLITitle],
            body: ProductStrings[.cliInstructionsBody],
            commands: [command]
        )
    }
}

/// The sheet both doors open: what to do, the exact lines, and one way to put
/// each on the pasteboard.
struct CoexistenceInstructionsSheet: View {
    let instructions: CoexistenceInstructions
    let dismiss: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(instructions.title)
                .fermixType(Typography.sheetTitle)
                .foregroundStyle(Palette.ink.color)

            Text(instructions.body)
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(instructions.commands, id: \.self) { command in
                    commandRow(command)
                }
            }

            HStack(spacing: Spacing.s) {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsSheetDone], action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(WindowMetrics.contentPadding)
        .frame(width: SheetMetrics.credentialWidth)
    }

    private func commandRow(_ command: String) -> some View {
        HStack(spacing: Spacing.s) {
            Text(command)
                .fermixType(Typography.style(.mono))
                .foregroundStyle(Palette.ink.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.s)

            Button(ProductStrings[.coexistenceCopyCommand]) { Clipboard.write(command) }
                .accessibilityLabel(
                    ProductStrings.commaPair(ProductStrings[.coexistenceCopyCommand], command)
                )
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.cardFill.color))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(
                Palette.hairline(.standard, increaseContrast: contrast == .increased).color,
                lineWidth: Stroke.hairline
            )
        )
    }
}
