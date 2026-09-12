import Foundation

/// The launch argument that asks for the staged development configuration,
/// whose background agent uses the isolated development home and port.
///
/// A **launch argument**, never an environment value, for the reason
/// `FixtureLaunchRequest` states: an overlay is inherited by everything a
/// process spawns and survives in a shell nobody is looking at, so a build that
/// read one could enter this configuration without anybody having asked for it
/// on that launch. An argument is stated once, per launch, by whoever typed it.
///
/// Parsing compiles into every build; the configuration behind it does not. A
/// release build that is handed the flag refuses it with one sentence and exits
/// non-zero, which is the whole of the release behaviour.
public enum DevelopmentEngineLaunchRequest {
    public static let flag = "--development-engine"
    public static let registrationFlag = "--register-background-service"

    /// Why a launch argument was refused. Each case names what was inspected.
    public enum Refusal: Error, Equatable {
        /// The flag was given twice. A launch argument that is quietly dropped
        /// is what makes a configuration nobody asked for look like the one
        /// that was requested.
        case flagRepeated
        case registrationFlagRepeated
        case registrationRequiresDevelopment
        /// Present in a build that has no development configuration compiled in.
        case notAvailableInThisBuild
        /// Two declared configurations at once. Neither is reachable from
        /// inside the other, so a launch naming both names nothing this build
        /// can do.
        case combinedWithFixture

        public var sentence: String {
            switch self {
            case .flagRepeated:
                return "\(DevelopmentEngineLaunchRequest.flag) was given more than once"
            case .registrationFlagRepeated:
                return "\(DevelopmentEngineLaunchRequest.registrationFlag) was given more than once"
            case .registrationRequiresDevelopment:
                return "\(DevelopmentEngineLaunchRequest.registrationFlag) requires \(DevelopmentEngineLaunchRequest.flag)"
            case .notAvailableInThisBuild:
                return """
                    \(DevelopmentEngineLaunchRequest.flag) is compiled into debug builds only, \
                    and this is a release build
                    """
            case .combinedWithFixture:
                return """
                    \(DevelopmentEngineLaunchRequest.flag) and \(FixtureLaunchRequest.flag) \
                    are two configurations, and one launch runs one of them
                    """
            }
        }
    }

    /// Whether this launch asked for the development configuration.
    ///
    /// The flag is counted rather than found, so a second one is refused rather
    /// than ignored.
    public static func parse(_ arguments: [String]) throws -> Bool {
        let asked = arguments.filter { $0 == flag }
        guard asked.count <= 1 else { throw Refusal.flagRepeated }
        let registrations = arguments.filter { $0 == registrationFlag }.count
        guard registrations <= 1 else { throw Refusal.registrationFlagRepeated }
        guard registrations == 0 || asked.count == 1 else { throw Refusal.registrationRequiresDevelopment }

        return asked.count == 1
    }
}
