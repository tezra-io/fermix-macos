import Foundation

/// What `--unregister-login-items` did, as lines a log can be read for and one
/// exit status.
///
/// The cask runs the verb from the copy it is about to replace, because the
/// registrations are keyed on this bundle and nothing else can withdraw them.
/// On 2026-09-17 a `brew upgrade --cask fermix` ran it and the BTM item and the
/// launchd job both survived, with nothing in the upgrade log to say so — the
/// agent then spawned without a PATH and refused every launch. So the outcome
/// is a value: macOS is read back after every withdrawal, and a registration
/// that is still there is a refusal rather than a silent success.
public struct LoginItemWithdrawal: Equatable, Sendable {
    /// One principal's outcome, as the sentence it prints.
    public struct Line: Equatable, Sendable {
        public let sentence: String
        public let withdrawn: Bool

        public init(sentence: String, withdrawn: Bool) {
            self.sentence = sentence
            self.withdrawn = withdrawn
        }
    }

    public let lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines
    }

    public var succeeded: Bool { lines.allSatisfy(\.withdrawn) }

    /// `EX_SOFTWARE`, which is what the verb already exited with, so a cask
    /// that reads the status keeps reading the same one.
    public var exitCode: Int32 { succeeded ? 0 : 70 }

    /// Withdraws every registration this bundle owns.
    ///
    /// Every principal, rather than a list written here: a registration this
    /// app learns to make later is one an uninstall has to take back, and a
    /// hand-kept list is how it would be left behind.
    public static func run(services: ServiceController) -> LoginItemWithdrawal {
        LoginItemWithdrawal(lines: LoginItemPrincipal.allCases.map { withdraw($0, services: services) })
    }

    /// One principal: read, withdraw, read back.
    ///
    /// Nothing to withdraw is not a fault — the cask runs this on every upgrade,
    /// including for an account that never turned the background service on —
    /// but an item macOS still reports afterwards is, whatever `unregister`
    /// answered.
    private static func withdraw(
        _ principal: LoginItemPrincipal,
        services: ServiceController
    ) -> Line {
        let before = services.status(principal)
        guard before != .notRegistered else {
            return Line(
                sentence: "\(principal.rawValue) was not registered, so there was nothing to withdraw",
                withdrawn: true
            )
        }

        do {
            try services.disable(principal)
        } catch {
            return Line(
                sentence: "\(principal.rawValue) could not be unregistered: \(error)",
                withdrawn: false
            )
        }

        let after = services.status(principal)
        guard after == .notRegistered else {
            return Line(
                sentence: "\(principal.rawValue) is still \(after.rawValue) after being unregistered",
                withdrawn: false
            )
        }

        return Line(sentence: "unregistered \(principal.rawValue)", withdrawn: true)
    }
}
