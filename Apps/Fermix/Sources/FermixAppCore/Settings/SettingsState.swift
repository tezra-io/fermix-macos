import Foundation

/// The states a protocol v2 read can be in.
///
/// Three, not two: a daemon one release behind the bundle refuses a v2 method
/// with `methodRequiresNewerEngine`, and M34 §7.1 renders that as a named state
/// with one action — never as an error and never as an empty pane.
public enum SettingsReadState<Value: Equatable & Sendable>: Equatable, Sendable {
    case unread
    case loading
    case loaded(Value)
    case requiresNewerEngine
    /// The daemon refused, in its own words.
    case unavailable(String)

    public var value: Value? {
        guard case .loaded(let value) = self else { return nil }

        return value
    }

    public var isLoading: Bool { self == .loading }

    /// Classifies a refusal the way M34 §7.1 does: the N-1 window is a state,
    /// everything else is the daemon's sentence.
    public static func failure(_ error: any Error) -> Self {
        ManagementMessage.requiresNewerEngine(error)
            ? .requiresNewerEngine
            : .unavailable(ManagementMessage.sentence(for: error))
    }
}

/// Whether the daemon in memory can serve the surface this bundle was built for
/// (M34 §7.1, §7.2).
///
/// One value with two inputs, owned by `SettingsModel` and read by everything
/// else. Two facts can say no and neither implies the other, so both are kept:
/// the launch comparison of build ids, which Home writes after every `hello`,
/// and whether a v2 method has refused, which the settings reads write. Held as
/// two properties on one value rather than as two properties on two models,
/// where they were both named `engineReconcile`, both had an `aligned` case,
/// and the one restart sheet took its title from whichever of them its caller
/// happened to hold.
public struct EngineReconcile: Equatable, Sendable {
    /// What the launch reconcile found. `daemonUnreachable` until Home has read
    /// a `hello`, because nothing has been compared yet.
    public var builds: EngineReconcileOutcome
    /// Whether a v2 method refused with the N-1 window since the last read that
    /// worked. Every settings surface is protocol v2, so this one fact answers
    /// for all of them.
    public var methodsRefused: Bool

    public init(builds: EngineReconcileOutcome = .daemonUnreachable, methodsRefused: Bool = false) {
        self.builds = builds
        self.methodsRefused = methodsRefused
    }

    /// Whether the panes can be served at all right now.
    public var requiresNewerEngine: Bool { methodsRefused }

    /// Whether a restart would actually change the engine that is answering.
    ///
    /// The build comparison alone, because that is the whole mechanism: launchd
    /// brings back the engine this bundle ships, so a restart applies something
    /// new exactly when the bundle ships something new. A refused v2 method used
    /// to count too, which offered `Restart to finish updating` on a daemon that
    /// already *is* the bundled engine: the restart brought the same engine back
    /// and the panes refused again (owner report of 2026-09-04).
    public var isFinishingUpdate: Bool { builds.isPending }

    /// The panes refused and no restart can help: the engine this copy of
    /// Fermix ships is itself older than the panes need. It is the state a
    /// pre-v2-engine install and the dev loop are both in, and the honest thing
    /// to say about it is that the app is ahead of its own engine.
    public var engineBehindApp: Bool { methodsRefused && !isFinishingUpdate }

    /// The one sentence every surface says about a daemon that cannot serve the
    /// panes, so the banner, each pane's notice and Home's Attention row cannot
    /// describe one state two ways.
    public var newerEngineSentence: String {
        ProductStrings[isFinishingUpdate ? .settingsRequiresNewerEngine : .settingsEngineBehindApp]
    }
}

/// One row's value, as the pane currently shows it.
///
/// A draft is the operator's uncommitted edit. It lives in the model rather
/// than in the view so a pane that is rebuilt (a search, a window resize, a
/// refresh) does not lose what was typed into it.
public struct SettingsDraftKey: Hashable, Sendable {
    public let section: String
    public let key: String

    public init(section: String, key: String) {
        precondition(!section.isEmpty, "a draft belongs to a section")
        precondition(!key.isEmpty, "a draft belongs to a row")

        self.section = section
        self.key = key
    }
}

/// Which restart the operator asked for.
public enum RestartMode: String, CaseIterable, Sendable {
    case now
    /// Waits until nothing is in flight, up to the published cap, and asks
    /// again rather than restarting a conversation without saying so.
    case whenIdle
}

/// What the Settings surface can be doing about a restart right now.
public enum RestartProgress: Equatable, Sendable {
    case idle
    case waitingForIdle
    /// The wait reached its cap with work still in flight, so the sheet asks
    /// again rather than deciding for the operator.
    case stillBusy
}
