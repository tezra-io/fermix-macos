import Foundation

/// The launch argument that starts the app hidden (plan §4.0): a task selects
/// the Fermix browser with no host attached, and the daemon launches the app
/// with `open -g -j -b <bundle id> --args --background` and waits for the
/// attach. This flag is what tells the launch to open no window and keep the
/// status item, exactly as a login launch does.
///
/// A **launch argument**, never an environment value, for the reason
/// `FixtureLaunchRequest` states: an overlay is inherited by everything a
/// process spawns and survives in a shell nobody is looking at, so a build
/// that read one could enter the background role without a task having asked
/// for it on that launch. An argument is stated once, per launch, by whoever
/// typed it.
///
/// Parsing compiles into every build, release included: a task can start the
/// app on any Mac running Fermix, not only a debug one.
public enum BackgroundLaunchRequest {
    public static let flag = "--background"

    /// Why a launch argument was refused. Each case names what was inspected.
    public enum Refusal: Error, Equatable {
        /// The flag was given twice. A launch argument that is quietly dropped
        /// is what makes a configuration nobody asked for look like the one
        /// that was requested.
        case flagRepeated
        /// Showing a fixture surface with no window to show it in is not a
        /// launch either configuration can honour.
        case combinedWithFixture

        public var sentence: String {
            switch self {
            case .flagRepeated:
                return "\(BackgroundLaunchRequest.flag) was given more than once"
            case .combinedWithFixture:
                return """
                    \(BackgroundLaunchRequest.flag) and \(FixtureLaunchRequest.flag) \
                    are two configurations, and one launch runs one of them
                    """
            }
        }
    }

    /// Whether this launch asked to start hidden.
    ///
    /// The flag is counted rather than found, so a second one is refused
    /// rather than ignored.
    public static func parse(_ arguments: [String]) throws -> Bool {
        let asked = arguments.filter { $0 == flag }
        guard asked.count <= 1 else { throw Refusal.flagRepeated }

        return !asked.isEmpty
    }
}
