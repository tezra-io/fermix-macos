import Foundation

/// One node of a page, in the shape the engine's snapshot renderer reads
/// (`browser/snapshot.ex`): Chrome's accessibility node, normalized.
///
/// Its coding is the wire's: `id`, `role`, `name`, `value`, `properties`,
/// `ref` and `childIds`, where `ref` stands where Chrome's
/// `backendDOMNodeId` does and is present only on a node an action reaches.
public struct BrowserPageNode: Codable, Equatable, Sendable {
    /// The three properties the renderer reads, and the flag on a frame whose
    /// content is out of the script's reach.
    public struct Properties: Codable, Equatable, Sendable {
        /// `plaintext` or `richtext`, as Chrome spells it.
        public var editable: String?
        public var settable: Bool?
        public var url: String?
        public var crossOrigin: Bool?

        public init(editable: String? = nil, settable: Bool? = nil, url: String? = nil, crossOrigin: Bool? = nil) {
            self.editable = editable
            self.settable = settable
            self.url = url
            self.crossOrigin = crossOrigin
        }

        enum CodingKeys: String, CodingKey {
            case editable
            case settable
            case url
            case crossOrigin = "cross_origin"
        }
    }

    public var id: Int
    public var role: String
    public var name: String
    public var value: String?
    public var properties: Properties?
    /// The page script's key for the node an action reaches, stable for as
    /// long as the node lives.
    public var ref: Int?
    public var childIds: [Int]

    public init(
        id: Int,
        role: String,
        name: String = "",
        value: String? = nil,
        properties: Properties? = nil,
        ref: Int? = nil,
        childIds: [Int] = []
    ) {
        self.id = id
        self.role = role
        self.name = name
        self.value = value
        self.properties = properties
        self.ref = ref
        self.childIds = childIds
    }
}

/// How far a document has loaded: `document.readyState`, in the words the
/// wire's `ready_state` takes.
public enum BrowserReadyState: String, Equatable, Sendable, Decodable {
    case loading
    case interactive
    case complete
}

/// A page as one snapshot read it.
public struct BrowserPageSnapshot: Equatable, Sendable {
    public var title: String
    public var url: String
    /// `document.readyState` as the snapshot read the page: a look whose
    /// budget ran out reads a page still loading as it stands.
    public var readyState: BrowserReadyState
    /// Whether WebKit had a navigation in flight in the tab when the page was
    /// read, taken beside the script's answer rather than when the answer is
    /// sent, by which time that navigation may have replaced the document.
    public var tabLoading: Bool
    /// The tree, root first: node 0 is the document.
    public var nodes: [BrowserPageNode]
    /// The elements the walk visited, hidden subtrees left out.
    public var elements: Int
    /// Frames whose content the script could not reach, and so did not list.
    public var crossOriginFrames: Int
    /// Whether closed shadow roots were in reach. Only a content world
    /// configured for them on macOS 27 reaches them; otherwise they are
    /// skipped, and this says so.
    public var closedShadowRoots: Bool
    /// The whole evaluate, from the app's call to its decoded answer.
    public var evaluateMilliseconds: Double

    public init(
        title: String,
        url: String,
        readyState: BrowserReadyState,
        tabLoading: Bool,
        nodes: [BrowserPageNode],
        elements: Int,
        crossOriginFrames: Int,
        closedShadowRoots: Bool,
        evaluateMilliseconds: Double
    ) {
        self.title = title
        self.url = url
        self.readyState = readyState
        self.tabLoading = tabLoading
        self.nodes = nodes
        self.elements = elements
        self.crossOriginFrames = crossOriginFrames
        self.closedShadowRoots = closedShadowRoots
        self.evaluateMilliseconds = evaluateMilliseconds
    }

    /// The page script's answer, read and checked: the root comes first, ids
    /// are the nodes' own positions, and every child id names a node.
    /// `tabLoading` is whether WebKit had a navigation in flight as it answered.
    public static func decode(_ json: Data, tabLoading: Bool, evaluateMilliseconds: Double) throws -> BrowserPageSnapshot {
        let answer: Answer
        do {
            answer = try JSONDecoder().decode(Answer.self, from: json)
        } catch {
            throw BrowserPageDriveError.script("unreadable snapshot: \(error)")
        }
        try checkTree(answer.nodes)

        return BrowserPageSnapshot(
            title: answer.title,
            url: answer.url,
            readyState: answer.readyState,
            tabLoading: tabLoading,
            nodes: answer.nodes,
            elements: answer.elements,
            crossOriginFrames: answer.crossOriginFrames,
            closedShadowRoots: answer.closedShadowRoots,
            evaluateMilliseconds: evaluateMilliseconds
        )
    }

    /// The `ready_state` the wire reports for this read: the document's own,
    /// except that a complete document read while the tab was still loading
    /// is the one a navigation in flight had not yet replaced, so the tab was
    /// still `loading`.
    public var reportedReadyState: BrowserReadyState {
        tabLoading && readyState == .complete ? .loading : readyState
    }

    private struct Answer: Decodable {
        let title: String
        let url: String
        let readyState: BrowserReadyState
        let nodes: [BrowserPageNode]
        let elements: Int
        let crossOriginFrames: Int
        let closedShadowRoots: Bool
    }

    private static func checkTree(_ nodes: [BrowserPageNode]) throws {
        guard nodes.first?.role == "RootWebArea" else {
            throw BrowserPageDriveError.script("snapshot has no document root")
        }
        for (position, node) in nodes.enumerated() {
            guard node.id == position else {
                throw BrowserPageDriveError.script("snapshot node \(position) carries id \(node.id)")
            }
            guard node.childIds.allSatisfy({ $0 > node.id && $0 < nodes.count }) else {
                throw BrowserPageDriveError.script("snapshot node \(node.id) names a child it does not hold")
            }
        }
    }
}

/// What an action is judged by: where the page is, what it is called, how many
/// elements it has, how much text its body holds, and which element holds the
/// focus.
public struct BrowserPageFingerprint: Decodable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var elements: Int
    /// The length of the body's `textContent`, so a page whose words change
    /// and whose elements do not has still moved.
    public var text: Int
    /// The page script's key for the focused element, 0 for none.
    public var focus: Int
    /// `document.readyState`.
    public var ready: String

    public init(url: String, title: String, elements: Int, text: Int, focus: Int, ready: String) {
        self.url = url
        self.title = title
        self.elements = elements
        self.text = text
        self.focus = focus
        self.ready = ready
    }

    /// Two looks show the same page. The ready state is how far the page has
    /// loaded, not what it is, so it takes no part.
    public func isSamePage(as other: BrowserPageFingerprint) -> Bool {
        url == other.url && title == other.title && elements == other.elements && text == other.text
            && focus == other.focus
    }
}

/// A page-script answer: its value, or the one word it refused with.
public enum BrowserScriptAnswer<Value: Decodable>: Decodable {
    case value(Value)
    case refused(String)

    private enum Keys: String, CodingKey {
        case error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let word = try container.decodeIfPresent(String.self, forKey: .error) {
            self = .refused(word)
            return
        }
        self = .value(try Value(from: decoder))
    }

    /// The value, or the refusal as the error for the ref it was about.
    public func value(for ref: Int) throws -> Value {
        switch self {
        case .value(let value): return value
        case .refused(let word): throw BrowserPageDriveError.refusal(word, ref: ref)
        }
    }
}
