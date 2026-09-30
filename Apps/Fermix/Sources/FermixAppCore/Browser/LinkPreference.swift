import Foundation

/// Where a person's clicked link opens (plan §4.5): in the pane beside the
/// surface, or in their own browser.
public enum LinkDestination: String, CaseIterable, Sendable {
    case fermix
    case system
}

/// Where the clicked-link preference is remembered.
///
/// The app's own preference, not the daemon's: where a link opens is a choice
/// about this window, and the engine never reads it. Main-actor isolated
/// because the one reader, the content link opener, is.
@MainActor
public protocol LinkPreferenceStoring: AnyObject {
    var linkDestination: LinkDestination { get set }
}

/// The shipped store, under `browser.linkDestination`. A value this build does
/// not know reads as the default, the pane, which is where a link opened before
/// anybody chose.
@MainActor
public final class UserDefaultsLinkPreferenceStore: LinkPreferenceStoring {
    public static let key = "browser.linkDestination"
    public static let defaultDestination = LinkDestination.fermix

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var linkDestination: LinkDestination {
        get { defaults.string(forKey: Self.key).flatMap(LinkDestination.init(rawValue:)) ?? Self.defaultDestination }
        set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}
