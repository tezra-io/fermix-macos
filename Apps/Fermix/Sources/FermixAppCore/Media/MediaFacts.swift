import AVFoundation
import Foundation

/// What AVFoundation says of a sound or a film before anything plays it
/// (M66 §3.4, §3.7): whether it can play at all, asked of the file itself and
/// never read from its name, and how long it is. The one owner of both, for
/// the pane's media tabs, the chat's sounds and a video tile's preview alike.
///
/// Nonisolated, since a tile's preview asks it off the main thread, and
/// behind a protocol, so no test opens a file.
public protocol MediaFacts: Sendable {
    func isPlayable(_ file: URL) async -> Bool
    /// Its length in seconds, where it has a real, positive one.
    func length(of file: URL) async -> Double?
}

/// AVFoundation's own answers, loaded asynchronously. What it cannot play
/// opens outside Fermix (M66 §3.3).
public struct AVFoundationMediaFacts: MediaFacts {
    public init() {}

    public func isPlayable(_ file: URL) async -> Bool {
        (try? await AVURLAsset(url: file).load(.isPlayable)) == true
    }

    public func length(of file: URL) async -> Double? {
        Self.seconds(try? await AVURLAsset(url: file).load(.duration))
    }

    /// A time as a length in seconds, where it is a real, positive one: the
    /// one reading of a duration, the held item's among them.
    static func seconds(_ time: CMTime?) -> Double? {
        guard let time, time.isNumeric, time.seconds > 0 else { return nil }

        return time.seconds
    }
}
