import Foundation

/// How much of a page a snapshot lists: the engine's `interactive` flag.
///
/// `Decodable` because the host wire's `page.snapshot`, `tab.open` and
/// `page.act` requests carry this same word (`BrowserHostProtocol.swift`);
/// one vocabulary rather than a second copy of the two words.
public enum BrowserSnapshotMode: String, Equatable, Sendable, Decodable {
    case interactive
    case full
}

/// What the engine asked a snapshot for (plan §4.1, `page.snapshot`).
///
/// The engine's renderer does the truncating. The page script reads these as
/// hints that bound its walk, and never below what the renderer would keep.
public struct BrowserSnapshotRequest: Equatable, Sendable {
    public var mode: BrowserSnapshotMode
    public var maxChars: Int
    public var depth: Int

    public init(mode: BrowserSnapshotMode, maxChars: Int, depth: Int) {
        self.mode = mode
        self.maxChars = maxChars
        self.depth = depth
    }
}

/// One field of a `fill_form`, by the ref a snapshot gave it.
public struct BrowserFormField: Equatable, Sendable {
    public let ref: Int
    public let text: String

    public init(ref: Int, text: String) {
        self.ref = ref
        self.text = text
    }
}

/// The engine's act kinds (plan §4.1, `page.act` and `page.upload`), by the
/// refs a snapshot handed out.
public enum BrowserPageAction: Equatable, Sendable {
    case click(ref: Int)
    /// A point of the page's layout viewport, in CSS pixels.
    case clickCoordinates(x: Double, y: Double)
    /// Replaces what the field holds.
    case fill(ref: Int, text: String)
    case fillForm([BrowserFormField])
    /// Appends at the end of what the field holds.
    case type(ref: Int, text: String)
    case press(key: String)
    case hover(ref: Int)
    /// A `select`'s option, by its value or its label.
    case select(ref: Int, value: String)
    case submit(ref: Int)
    /// Scrolls by CSS pixels: the ref's own scroller, or the page with no ref.
    case scroll(ref: Int?, x: Double, y: Double)
    case upload(ref: Int, path: String)
}

/// How the page received an action.
///
/// `trusted` is input from the Mac, delivered to the web view as a person's
/// would be, which the page sees with `isTrusted` true. `scripted` is a value
/// set or an event dispatched by the page script, which the page sees with
/// `isTrusted` false.
public enum BrowserInputPath: String, Equatable, Sendable {
    case trusted
    case scripted
}

/// What an action did to the page, the way the engine reports it: `changed`
/// with a fresh snapshot, or `unchanged`, which means the refs the engine
/// holds are still good. `unobserved` is a page that stopped answering its
/// script once the action was done, as one holding a dialog does; the action
/// itself stands.
public enum BrowserPageEffect: Equatable, Sendable {
    case changed(BrowserPageSnapshot)
    case unchanged
    case unobserved
}

/// One filled field of a `fill_form`, as the engine's receipt lists it.
public struct BrowserFieldReceipt: Equatable, Sendable {
    public let ref: Int
    public let value: String

    public init(ref: Int, value: String) {
        self.ref = ref
        self.value = value
    }
}

/// What an action did, and what it leaves for the engine to confirm it by.
public struct BrowserActOutcome: Equatable, Sendable {
    public var effect: BrowserPageEffect
    public var input: BrowserInputPath
    /// The page's address once it settled.
    public var url: String
    /// The field's value after a fill or a type.
    public var value: String?
    /// The fields a `fill_form` filled, in order.
    public var filled: [BrowserFieldReceipt]?
    /// The label of the control a submit clicked, or `form.requestSubmit()`.
    public var submitted: String?
    /// The file name the page's file input holds after an upload.
    public var uploaded: String?

    public init(
        effect: BrowserPageEffect,
        input: BrowserInputPath,
        url: String,
        value: String? = nil,
        filled: [BrowserFieldReceipt]? = nil,
        submitted: String? = nil,
        uploaded: String? = nil
    ) {
        self.effect = effect
        self.input = input
        self.url = url
        self.value = value
        self.filled = filled
        self.submitted = submitted
        self.uploaded = uploaded
    }
}

/// Why a page could not be read or acted on.
public indirect enum BrowserPageDriveError: Error, Equatable, Sendable {
    /// The tab's page has no web engine that reads or acts (the fixture's).
    case notDrivable
    /// The ref's node is gone from the page.
    case staleRef(Int)
    /// The ref's node has no box on screen to click, as a visually hidden
    /// styled input has none; its label is what a person clicks.
    case noRenderedBox(Int)
    /// The point lies outside the web view, so no input can reach it.
    case outsideView
    case unknownKey(String)
    case notEditable(Int)
    case notSelect(Int)
    case noOption(Int)
    case noForm(Int)
    case notFileInput(Int)
    /// The page's file input never asked for a file, or never took it.
    case uploadNotAccepted(Int)
    /// The page's view is in no window, so it cannot take input.
    case detached
    /// The page script did not answer in time: a dialog holds the page.
    case unresponsive
    /// The page script threw, or answered something that is not its shape.
    case script(String)
    /// A `fill_form` stopped at a field; the ones before it were filled.
    case formStopped(at: Int, filled: [BrowserFieldReceipt], cause: BrowserPageDriveError)

    /// The page script's one-word refusal, for the ref it was about.
    public static func refusal(_ word: String, ref: Int) -> BrowserPageDriveError {
        switch word {
        case "stale": return .staleRef(ref)
        case "no_box": return .noRenderedBox(ref)
        case "not_editable": return .notEditable(ref)
        case "not_select": return .notSelect(ref)
        case "no_option": return .noOption(ref)
        case "no_form": return .noForm(ref)
        case "not_file_input": return .notFileInput(ref)
        default: return .script(word)
        }
    }
}

/// A page as the engine reads it (plan §4.2, the host action `snapshot`).
@MainActor
public protocol BrowserPageReading: AnyObject {
    func snapshot(_ request: BrowserSnapshotRequest) async throws -> BrowserPageSnapshot
}

/// A page as the engine acts on it (plan §4.2, the host action `act`).
///
/// `observing` is the snapshot the engine would take next, so a `changed`
/// page comes back already read.
@MainActor
public protocol BrowserPageActing: AnyObject {
    func act(_ action: BrowserPageAction, observing request: BrowserSnapshotRequest) async throws -> BrowserActOutcome
}

public typealias BrowserPageDriving = BrowserPageReading & BrowserPageActing
