import Foundation

/// A closed set of published wire values that must nonetheless survive contact
/// with a value it does not know.
///
/// An unknown value is *preserved*, never mapped onto a neighbour and never
/// dropped: the app can then say exactly what the daemon sent. It is not a
/// fallback path — there is one decode, and the caller switches on a case that
/// is honestly labelled unrecognised.
public protocol ManagementVocabulary: Codable, Equatable, Sendable {
    static var publishedValues: [String: Self] { get }
    static func unrecognizedCase(_ value: String) -> Self
    var unrecognizedValue: String? { get }
}

extension ManagementVocabulary {
    public init(wireValue: String) {
        self = Self.publishedValues[wireValue] ?? Self.unrecognizedCase(wireValue)
    }

    public var wireValue: String {
        if let value = unrecognizedValue { return value }
        guard let published = Self.publishedValues.first(where: { $0.value == self })?.key else {
            preconditionFailure("\(Self.self) case is neither published nor unrecognised")
        }
        return published
    }

    public var isPublished: Bool { unrecognizedValue == nil }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    /// The wire value, published or preserved. An unrecognised value goes back
    /// out exactly as it came in: a diagnostics export that dropped it would
    /// hide the one field a reader needs.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// The eleven published management methods.
public enum ManagementMethod: String, CaseIterable, Sendable {
    case hello = "hello"
    case overviewGet = "overview.get"
    case setupSessionCreate = "setup.session.create"
    case doctorStart = "doctor.start"
    case doctorGet = "doctor.get"
    case doctorCancel = "doctor.cancel"
    case logsQuery = "logs.query"
    case lifecyclePrepare = "lifecycle.prepare"
    case lifecycleCommit = "lifecycle.commit"
    case lifecycleCancel = "lifecycle.cancel"
    case diagnosticsBuild = "diagnostics.build"

    /// The method name in a form the request-id pattern accepts.
    public var identifierSlug: String { rawValue.replacingOccurrences(of: ".", with: "-") }
}

public enum ManagementErrorCode: ManagementVocabulary {
    case invalidRequest
    case invalidParams
    case methodNotFound
    case clientTooOld
    case daemonTooOld
    case internalError
    case unavailable
    case busy
    case leaseExpired
    case unknownLease
    case unknownSession
    case cursorExpired
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "invalid_request": .invalidRequest,
        "invalid_params": .invalidParams,
        "method_not_found": .methodNotFound,
        "client_too_old": .clientTooOld,
        "daemon_too_old": .daemonTooOld,
        "internal_error": .internalError,
        "unavailable": .unavailable,
        "busy": .busy,
        "lease_expired": .leaseExpired,
        "unknown_lease": .unknownLease,
        "unknown_session": .unknownSession,
        "cursor_expired": .cursorExpired
    ]

    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }

    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementDoctorScope: ManagementVocabulary {
    case local
    case network
    case unrecognized(String)

    public static let publishedValues: [String: Self] = ["local": .local, "network": .network]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementDoctorStatus: ManagementVocabulary {
    case running
    case completed
    case cancelled
    case timedOut
    case failed
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "running": .running,
        "completed": .completed,
        "cancelled": .cancelled,
        "timed_out": .timedOut,
        "failed": .failed
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementCheckStatus: ManagementVocabulary {
    case passed
    case warning
    case failed
    case notApplicable
    case unavailable
    case skipped
    case cancelled
    case timedOut
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "passed": .passed,
        "warning": .warning,
        "failed": .failed,
        "not_applicable": .notApplicable,
        "unavailable": .unavailable,
        "skipped": .skipped,
        "cancelled": .cancelled,
        "timed_out": .timedOut
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementCheckCategory: ManagementVocabulary {
    case runtime
    case configuration
    case security
    case capability
    case connectivity
    case distribution
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "runtime": .runtime,
        "configuration": .configuration,
        "security": .security,
        "capability": .capability,
        "connectivity": .connectivity,
        "distribution": .distribution
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementCheckSeverity: ManagementVocabulary {
    case critical
    case warning
    case info
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "critical": .critical,
        "warning": .warning,
        "info": .info
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementCheckApplicability: ManagementVocabulary {
    case always
    case configured
    case platform
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "always": .always,
        "configured": .configured,
        "platform": .platform
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementLogLevel: ManagementVocabulary {
    case emergency
    case alert
    case critical
    case error
    case warning
    case notice
    case info
    case debug
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "emergency": .emergency,
        "alert": .alert,
        "critical": .critical,
        "error": .error,
        "warning": .warning,
        "notice": .notice,
        "info": .info,
        "debug": .debug
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementLogDirection: ManagementVocabulary {
    case backward
    case forward
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "backward": .backward,
        "forward": .forward
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}

public enum ManagementLifecycleOutcome: ManagementVocabulary {
    case committed
    case cancelled
    case unrecognized(String)

    public static let publishedValues: [String: Self] = [
        "committed": .committed,
        "cancelled": .cancelled
    ]
    public static func unrecognizedCase(_ value: String) -> Self { .unrecognized(value) }
    public var unrecognizedValue: String? {
        if case .unrecognized(let value) = self { return value }
        return nil
    }
}
