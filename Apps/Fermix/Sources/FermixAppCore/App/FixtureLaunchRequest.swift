import Foundation

/// The launch argument that asks for the fixture configuration.
///
/// A **launch argument**, never an environment value. An environment overlay is
/// inherited by everything a process spawns and survives in a shell nobody is
/// looking at, so a build that read one could enter the fixture configuration
/// without anybody having asked for it on that launch. An argument is stated
/// once, per launch, by whoever typed it.
///
/// Parsing compiles into every build; the configuration behind it does not. A
/// release build that is handed the flag refuses it with one sentence and exits
/// non-zero, which is the whole of the release behaviour.
public enum FixtureLaunchRequest {
    public static let flag = "--fixture"
    public static let startFlag = "--fixture-start"
    /// Which glass the sheets wear on this launch (`SheetGroundRecipe`). A
    /// fixture launch's alone: it is how the two recipes are captured side by
    /// side, and no other launch can name one.
    public static let sheetGroundFlag = "--sheet-ground"
    /// Where a launch that names no surface lands.
    public static let defaultStart = "home"

    /// Why a launch argument was refused. Each case names what was inspected.
    public enum Refusal: Error, Equatable {
        case startWithoutFlag
        case startWithoutValue
        /// Carries the flag that was repeated: a refusal that named the wrong
        /// one sends the reader looking at the argument they typed once.
        case flagRepeated(String)
        /// Present in a build that has no fixture configuration compiled in.
        case notAvailableInThisBuild
        case unknownStart(String)
        case sheetGroundWithoutFlag
        case sheetGroundWithoutValue
        case unknownSheetGround(String)

        public var sentence: String {
            switch self {
            case .startWithoutFlag:
                return "\(FixtureLaunchRequest.startFlag) needs \(FixtureLaunchRequest.flag)"
            case .startWithoutValue:
                return "\(FixtureLaunchRequest.startFlag) needs a surface to open"
            case .flagRepeated(let repeated):
                return "\(repeated) was given more than once"
            case .notAvailableInThisBuild:
                return """
                    \(FixtureLaunchRequest.flag) is compiled into debug builds only, \
                    and this is a release build
                    """
            case .unknownStart(let name):
                return "no surface is called \"\(name)\""
            case .sheetGroundWithoutFlag:
                return "\(FixtureLaunchRequest.sheetGroundFlag) needs \(FixtureLaunchRequest.flag)"
            case .sheetGroundWithoutValue:
                return "\(FixtureLaunchRequest.sheetGroundFlag) needs one of \(Self.sheetGroundNames)"
            case .unknownSheetGround(let name):
                return "no sheet ground is called \"\(name)\", only \(Self.sheetGroundNames)"
            }
        }

        private static var sheetGroundNames: String {
            SheetGroundRecipe.allCases.map(\.rawValue).joined(separator: ", ")
        }
    }

    /// The surface named on the command line, or nil where the flag is absent.
    ///
    /// A flag with a name this build does not publish is refused rather than
    /// resolved to Home: opening a surface nobody asked for would report the
    /// argument as having worked.
    public static func parse(_ arguments: [String]) throws -> String? {
        // Both flags are counted, not just the first one found: a second
        // `--fixture-start` would otherwise be dropped and the app would open
        // the surface the operator asked for first, which is the same "reports
        // the argument as having worked" failure this type refuses above.
        let asked = arguments.filter { $0 == flag }
        let starts = arguments.filter { $0 == startFlag }
        guard asked.count <= 1 else { throw Refusal.flagRepeated(flag) }
        guard starts.count <= 1 else { throw Refusal.flagRepeated(startFlag) }

        guard let index = arguments.firstIndex(of: startFlag) else {
            return asked.isEmpty ? nil : defaultStart
        }
        guard !asked.isEmpty else { throw Refusal.startWithoutFlag }

        let value = arguments.index(after: index)
        guard value < arguments.endIndex, !arguments[value].hasPrefix("-") else {
            throw Refusal.startWithoutValue
        }

        return arguments[value]
    }

    /// The sheet ground this launch names, or the standard one where it names
    /// none.
    ///
    /// Refused without `--fixture`, with no value, repeated or naming a recipe
    /// this build does not have, for the reason `parse` refuses its own: a
    /// launch that drew the standard glass after being asked for another would
    /// report the argument as having worked.
    public static func sheetGround(_ arguments: [String]) throws -> SheetGroundRecipe {
        let named = arguments.filter { $0 == sheetGroundFlag }
        guard named.count <= 1 else { throw Refusal.flagRepeated(sheetGroundFlag) }
        guard let index = arguments.firstIndex(of: sheetGroundFlag) else { return .standard }
        guard arguments.contains(flag) else { throw Refusal.sheetGroundWithoutFlag }

        let value = arguments.index(after: index)
        guard value < arguments.endIndex, !arguments[value].hasPrefix("-") else {
            throw Refusal.sheetGroundWithoutValue
        }
        guard let recipe = SheetGroundRecipe(rawValue: arguments[value]) else {
            throw Refusal.unknownSheetGround(arguments[value])
        }

        return recipe
    }
}
