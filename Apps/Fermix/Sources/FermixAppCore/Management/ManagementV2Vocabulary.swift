import Foundation

/// The closed wire vocabularies protocol v2 publishes.
///
/// Every one is a `ManagementVocabulary`, so a value this build does not know is
/// preserved as `.unrecognized(value)` and can be named back to the reader
/// rather than mapped onto a neighbour or dropped.

/// The thirteen Settings panes of M34 §3.4. A readiness failure and a settings
/// section both name the pane they belong to, so the two speak one vocabulary.
///
/// The wire values are the §3.4 route slugs verbatim, because `fermix://settings/
/// <pane>` routes on exactly these: the Coding agents pane is `coding` on the
/// wire and `codingAgents` in Swift, which is the surface title and not a second
/// spelling of the slug.
public enum ManagementSettingsPane: ManagementVocabulary {
    case providers
    case personality
    case memory
    case channels
    case integrations
    case voice
    case meetings
    case computer
    case codingAgents
    case search
    case images
    case sandbox
    case permissions
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "providers": .providers,
        "personality": .personality,
        "memory": .memory,
        "channels": .channels,
        "integrations": .integrations,
        "voice": .voice,
        "meetings": .meetings,
        "computer": .computer,
        "coding": .codingAgents,
        "search": .search,
        "images": .images,
        "sandbox": .sandbox,
        "permissions": .permissions
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// The six row kinds one `DescriptorForm` renders (M34 §7.7). A kind this build
/// does not know fails the contract test at re-vendor time; it is preserved here
/// so the failure names the value the daemon sent.
public enum ManagementSettingKind: ManagementVocabulary {
    case toggle
    case choice
    case text
    case number
    case secret
    case list
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "toggle": .toggle,
        "choice": .choice,
        "text": .text,
        "number": .number,
        "secret": .secret,
        "list": .list
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementJobStatus: ManagementVocabulary {
    case running
    case completed
    case failed
    case cancelled
    case timedOut
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "running": .running,
        "completed": .completed,
        "failed": .failed,
        "cancelled": .cancelled,
        "timed_out": .timedOut
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }

    /// Whether the job has stopped. A poller stops on this and never on a
    /// phase, which is free-form.
    public var isTerminal: Bool {
        switch self {
        case .running: return false
        case .completed, .failed, .cancelled, .timedOut: return true
        case .unrecognized: return false
        }
    }
}

/// The job families `Management.Jobs` owns.
///
/// Doctor is not one of them. It keeps its own session family (`doctor.start`,
/// `doctor.get`, `doctor.cancel`) with its own scope and per-check results, so
/// `job.list` never returns one and no job carries a Doctor result shape.
public enum ManagementJobKind: ManagementVocabulary, Hashable {
    case providerProbe
    case auth
    case authImport
    case pluginInstall
    case pluginCheck
    case pluginWorkspacesDiscover
    case pluginWorkspaceSelect
    case capabilityInstall
    case meetingsSignin
    case computerUseGrant
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "provider_probe": .providerProbe,
        "auth": .auth,
        "auth_import": .authImport,
        "plugin_install": .pluginInstall,
        "plugin_check": .pluginCheck,
        "plugin_workspaces_discover": .pluginWorkspacesDiscover,
        "plugin_workspace_select": .pluginWorkspaceSelect,
        "capability_install": .capabilityInstall,
        "meetings_signin": .meetingsSignin,
        "computer_use_grant": .computerUseGrant
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Why a job ended badly. Closed, so a caller can branch on the kind rather
/// than read the daemon's sentence: `unavailable` is a capability that is not
/// there, `refused` is the daemon declining, `timed_out` is the job's own
/// budget, and `internal_error` is a defect. The sentence is still the only
/// thing drawn.
public enum ManagementJobFailureCode: ManagementVocabulary {
    case unavailable
    case refused
    case timedOut
    case internalError
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "unavailable": .unavailable,
        "refused": .refused,
        "timed_out": .timedOut,
        "internal_error": .internalError
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// M34 §7.5's three configuration states. Only `externalChange` refuses writes,
/// and only it is answered with `Reload settings from disk`.
public enum ManagementConfigState: ManagementVocabulary {
    case clear
    case externalChange
    case configUnreadable
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "clear": .clear,
        "external_change": .externalChange,
        "config_unreadable": .configUnreadable
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Which launchd domain a foreign Fermix service unit lives in. On the wire
/// because M34 §15.2 gives the system-scope case its own sentence and its own
/// action, which no front end can pick from a bare boolean.
public enum ManagementServiceScope: ManagementVocabulary {
    case user
    case system
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["user": .user, "system": .system]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// What `setup.detect` may be asked about. The targets are explicit on every
/// call: the daemon probes what was asked and nothing else.
public enum ManagementDetectTarget: ManagementVocabulary {
    case existingPrimary
    case claudeCode
    case codexCLI
    case ollama
    case harnessVendors
    /// The meeting notetaker: both halves installed, and its Google sign-in.
    case meetbot
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "existing_primary": .existingPrimary,
        "claude_code": .claudeCode,
        "codex_cli": .codexCLI,
        "ollama": .ollama,
        "harness_vendors": .harnessVendors,
        "meetbot": .meetbot
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementAuthImportSource: ManagementVocabulary {
    case claudeCode
    case codexCLI
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "claude_code": .claudeCode,
        "codex_cli": .codexCLI
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementCapabilityTarget: ManagementVocabulary {
    case computerUseSidecar
    case meetbot
    case localSTT
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "computer_use_sidecar": .computerUseSidecar,
        "meetbot": .meetbot,
        "local_stt": .localSTT
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// What a Doctor remediation offers. `instructions` names a catalogue entry
/// carrying a sheet of commands, which is the only kind the coexistence rows
/// can be expressed in; `restart` and `reload` name the two things the app
/// already owns — the restart transaction and `settings.reload` — so the
/// daemon can point at them without naming a method.
public enum ManagementRemediationActionKind: ManagementVocabulary {
    case settingsPane
    case systemSettings
    case job
    case restart
    case reload
    case instructions
    case none
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "settings_pane": .settingsPane,
        "system_settings": .systemSettings,
        "job": .job,
        "restart": .restart,
        "reload": .reload,
        "instructions": .instructions,
        "none": .none
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Where a model list came from. A live fetch that fails answers `unavailable`;
/// it never degrades to the catalog under a `live` label.
public enum ManagementModelSource: ManagementVocabulary {
    case catalog
    case live
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["catalog": .catalog, "live": .live]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// Which method a plugin row's button runs (`x-plugin-vocabulary.actions`).
///
/// A word is not a routing key. `primary_verb` and `verbs` are the daemon's
/// English and are painted; `primary_action` and `actions` say what each of
/// those buttons does, and dispatch reads only these. An id this build does not
/// know draws no button rather than a guessed one.
public enum ManagementPluginAction: ManagementVocabulary, Hashable {
    case install
    case enable
    case disable
    case signIn
    case addToken
    case replaceToken
    case setUpClient
    case chooseWorkspace
    case check
    case disconnect
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "install": .install,
        "enable": .enable,
        "disable": .disable,
        "sign_in": .signIn,
        "add_token": .addToken,
        "replace_token": .replaceToken,
        "set_up_client": .setUpClient,
        "choose_workspace": .chooseWorkspace,
        "check": .check,
        "disconnect": .disconnect
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// How a plugin runs (`x-plugin-vocabulary.runtime_kinds`). Null on the wire is
/// the http rail that runs inside Fermix itself, which is why the field is
/// optional rather than carrying a third case.
public enum ManagementPluginRuntimeKind: ManagementVocabulary, Hashable {
    case localStdio
    case remoteMCP
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "local_stdio": .localStdio,
        "remote_mcp": .remoteMCP
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

/// The credential kind behind a plugin (`x-plugin-vocabulary.auth_kinds`). Null
/// on the wire is a plugin that needs none.
public enum ManagementPluginAuthKind: ManagementVocabulary, Hashable {
    case oauth
    case apiKey
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "oauth": .oauth,
        "api_key": .apiKey
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}
