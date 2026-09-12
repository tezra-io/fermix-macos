import Darwin
import Foundation

/// Validates a candidate Fermix home.
///
/// Two passes with different lifetimes:
///
/// - `normalize` answers what the path *is* — absolute, free of traversal, and
///   not one of the locations a home may never be. It is a property of the
///   record, so it is re-checked every time one is read.
/// - `checkAccess` answers whether this account can *use* it right now. That is
///   a runtime condition, so it is checked when a home is chosen.
///
/// The home usually does not exist yet, so ownership and writability are probed
/// on the nearest ancestor that does. A gate that probes a directory its own
/// caller has not created yet inspects nothing.
struct BootstrapHomeValidator {
    let location: BootstrapLocation
    let fileManager: FileManager

    func normalize(_ path: String) throws -> String {
        guard !path.isEmpty else { throw BootstrapHomeDefect.empty }

        let expanded = expandTilde(path)
        guard expanded.hasPrefix("/") else {
            throw BootstrapHomeDefect.notAbsolute(path: path)
        }
        guard !expanded.split(separator: "/").contains("..") else {
            throw BootstrapHomeDefect.relativeTraversal(path: path)
        }

        let cleaned = "/" + expanded
            .split(separator: "/")
            .filter { $0 != "." }
            .joined(separator: "/")
        // The rules are about where the home really lands, not how its path is
        // spelled: a user-owned symbolic link one level up carries a home into
        // iCloud Drive with no forbidden substring anywhere in the text.
        let normalized = resolvingSymlinks(cleaned)

        if let reason = forbiddenReason(for: normalized) {
            throw BootstrapHomeDefect.forbiddenLocation(path: normalized, reason: reason)
        }
        return normalized
    }

    /// The path with symbolic links resolved through its deepest existing
    /// ancestor, keeping the components below it verbatim.
    ///
    /// `URL.resolvingSymlinksInPath` resolves nothing at all unless the whole
    /// path exists, and a Fermix home usually does not exist yet — which is
    /// exactly the case the rules have to cover. The walk is bounded by the
    /// path's own depth.
    private func resolvingSymlinks(_ path: String) -> String {
        var suffix: [String] = []
        var candidate = path

        while candidate != "/" {
            if fileManager.fileExists(atPath: candidate) {
                let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
                return ([resolved] + suffix.reversed()).joined(separator: "/")
            }

            suffix.append((candidate as NSString).lastPathComponent)
            candidate = (candidate as NSString).deletingLastPathComponent
        }

        return path
    }

    func checkAccess(_ path: String) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw BootstrapHomeDefect.notADirectory(path: path)
        }

        let probe = existingAncestor(of: path)
        var status = stat()
        // The probe exists by construction, so a failing stat means this
        // account cannot even traverse to it — the same remedy as not being
        // able to write it.
        guard stat(probe, &status) == 0 else {
            throw BootstrapHomeDefect.notWritable(path: probe)
        }
        guard status.st_uid == geteuid() else {
            throw BootstrapHomeDefect.notOwnedByCurrentUser(path: probe, owner: status.st_uid)
        }
        guard access(probe, W_OK) == 0 else {
            throw BootstrapHomeDefect.notWritable(path: probe)
        }
    }

    /// The nearest ancestor of `path` that exists. The filesystem root always
    /// does, so the walk is bounded by the path's own depth.
    private func existingAncestor(of path: String) -> String {
        var candidate = path
        while candidate != "/" {
            if fileManager.fileExists(atPath: candidate) { return candidate }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return "/"
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return location.homeDirectory.path + String(path.dropFirst(1))
    }

    private func forbiddenReason(for path: String) -> ForbiddenHomeReason? {
        if path == "/" { return .filesystemRoot }
        if path == location.homeDirectory.path { return .accountHome }
        if isUnder(path, location.directoryURL.path) { return .bootstrapDirectory }
        if isUnder(path, location.homeDirectory.path + "/Library/Mobile Documents") {
            return .cloudSyncedDirectory
        }
        if Self.applicationRoots.contains(where: { isUnder(path, $0) })
            || isUnder(path, location.homeDirectory.path + "/Applications") {
            return .applicationsDirectory
        }
        if Self.temporaryRoots.contains(where: { isUnder(path, $0) }) { return .temporaryDirectory }
        if Self.systemRoots.contains(where: { isUnder(path, $0) }) { return .systemDirectory }
        return nil
    }

    private func isUnder(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static let applicationRoots = ["/Applications"]

    /// Shared, world-writable temporary storage. The per-user temporary
    /// directory (`/var/folders/…`) is deliberately not here: it is private to
    /// the account, and forbidding it would leave the rules untestable without
    /// writing into a real home.
    private static let temporaryRoots = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]

    private static let systemRoots = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/dev", "/Library", "/private/var/db"
    ]
}
