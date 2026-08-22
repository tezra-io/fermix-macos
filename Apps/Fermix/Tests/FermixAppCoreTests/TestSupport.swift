import Foundation

@testable import FermixAppCore

/// One-shot cross-thread signal for a callback delivered on a socket queue.
///
/// Replaces `XCTestExpectation` with the same semantics: `wait` blocks until
/// `fire` happens or the deadline passes, and reports which one occurred.
final class TestSignal {
    private let semaphore = DispatchSemaphore(value: 0)

    func fire() {
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

/// A suspension point a test opens by hand.
///
/// Used where the defect lives *inside* an await: a double parks there until the
/// case has done whatever the real world would have done in that window.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func release() {
        lock.withLock { opened = true }
    }

    func wait() async {
        while !lock.withLock({ opened }) {
            await Task.yield()
        }
    }
}

/// Thread-safe holder for a value captured from a socket-queue callback.
final class ValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Records what the agent wrote, so its entry point is testable without a
/// process or a file descriptor.
final class RecordingAgentOutput: AgentOutput {
    private let lock = NSLock()
    private var reported: [String] = []
    private var diagnosed: [String] = []

    func report(_ line: String) {
        lock.lock()
        reported.append(line)
        lock.unlock()
    }

    func diagnose(_ line: String) {
        lock.lock()
        diagnosed.append(line)
        lock.unlock()
    }

    var reports: [String] {
        lock.lock()
        defer { lock.unlock() }
        return reported
    }

    var diagnostics: [String] {
        lock.lock()
        defer { lock.unlock() }
        return diagnosed
    }
}

/// Answers the engine layout questions from two fixed sets of paths.
struct StubEngineProbe: EngineProbe {
    let directories: Set<String>
    let executables: Set<String>

    func directoryExists(at url: URL) -> Bool {
        directories.contains(url.path)
    }

    func executableExists(at url: URL) -> Bool {
        executables.contains(url.path)
    }
}

/// Reads the shipped Swift sources.
///
/// Some invariants are about *where a value is used*, not about what it
/// evaluates to: a design constant that no view applies is invisible to every
/// value assertion. Those gates scan the real tree, resolved from this file's
/// own compile-time path, so the case set comes from the product rather than
/// from a list somebody has to remember to update.
enum SourceTree {
    struct File {
        let path: String
        let text: String
    }

    /// The `Sources/FermixAppCore` directory of this checkout.
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FermixAppCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Apps/Fermix
            .appendingPathComponent("Sources/FermixAppCore", isDirectory: true)
    }

    /// Every `.swift` file under the source root, minus one relative path.
    ///
    /// A tree this cannot read is a failure, never a skipped gate: a scan that
    /// silently finds nothing passes every assertion it was written to make.
    static func swiftFiles(under relativePath: String, excluding: Bool) throws -> [File] {
        let root = Self.root
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw SourceTreeError.unreadable(path: root.path)
        }

        let excluded = root.appendingPathComponent(relativePath).path
        var files: [File] = []
        for case let name as String in enumerator where name.hasSuffix(".swift") {
            let path = root.appendingPathComponent(name).path
            if excluding, path == excluded { continue }
            files.append(File(path: path, text: try String(contentsOfFile: path, encoding: .utf8)))
        }

        guard !files.isEmpty else { throw SourceTreeError.empty(path: root.path) }
        return files
    }

    /// Every `.swift` file whose path contains `fragment`.
    static func swiftFiles(matching fragment: String) throws -> [File] {
        try swiftFiles(under: "", excluding: false).filter { $0.path.contains(fragment) }
    }

    /// The design system's published view modifiers, by name.
    ///
    /// They are all `public func fermix…` on `View`, so the set comes from the
    /// declarations themselves rather than from a list a reviewer maintains.
    static func declaredViewModifiers(in text: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: #"public func (fermix\w+)\("#)
        let range = NSRange(text.startIndex..., in: text)

        return pattern?.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        } ?? []
    }
}

enum SourceTreeError: Error, Equatable {
    case unreadable(path: String)
    case empty(path: String)
}

enum ProductFixture {
    /// A configuration document with the same shape as the shipped one, so a
    /// test can vary exactly one field.
    static func json(
        schemaVersion: Int = 1,
        productName: String = "Fermix",
        architectures: [String] = ["arm64", "x86_64"]
    ) -> Data {
        let architectureList = architectures
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        return Data(
            """
            {
              "schema_version": \(schemaVersion),
              "product_name": "\(productName)",
              "bundle_identifier": "io.tezra.FermixPet",
              "url_scheme": "fermix",
              "app_bundle_name": "FermixPet.app",
              "gui_executable_name": "Fermix",
              "agent_executable_name": "FermixAgent",
              "agent_service_label": "io.tezra.FermixPet.agent",
              "minimum_system_version": "15.0",
              "supported_architectures": [\(architectureList)],
              "marketing_version": "0.1.0",
              "build_number": "1",
              "icon_file": "FermixPet",
              "swift_resource_bundle_name": "Fermix_FermixAppCore.bundle",
              "engine_relative_path": "Contents/Resources/Engine",
              "tools_relative_path": "Contents/Resources/Tools",
              "microphone_usage_description": "Fermix uses microphone input only while you explicitly start a voice call."
            }
            """.utf8
        )
    }
}
