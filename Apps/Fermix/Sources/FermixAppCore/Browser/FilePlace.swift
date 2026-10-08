import Foundation

/// Where a path on this Mac really lands, and whether that is inside a root:
/// the one containment test, for the host's paths the engine names (an upload
/// from the workspace, a screenshot or a PDF into the browser directory) and
/// for a file the person opens in the pane, which opens silently only inside
/// the Fermix home.
///
/// It is decided on where both really are rather than how they are spelled,
/// as the engine decides it on its side (`Browser.Upload`): a symbolic link
/// inside the root that points out of it passes a test of the text.
public enum FilePlace {
    /// Up to `limit` bytes of the regular file at `path`, or nil where there
    /// is none there now. Read from one descriptor, opened without following a
    /// final link and without waiting on a pipe, then checked to be a regular
    /// file, so what is read is what was checked and nothing more: a file
    /// swapped since the pane decided for a link to `/dev/zero`, a pipe that
    /// never writes or a file that grew cannot hold the main thread.
    public static func contents(ofRegularFile path: String, upTo limit: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }

        return try? handle.read(upToCount: limit) ?? Data()
    }

    /// Whether `path` falls inside `root`. The root is resolved too, so a root
    /// reached through a link (`/tmp` is `/private/tmp`) still holds its own
    /// files.
    static func path(_ path: String, liesUnder root: URL) -> Bool {
        guard let resolvedRoot = resolved(root.path), let resolvedPath = resolved(path) else { return false }

        return resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")
    }

    /// Where `path` really lands: its deepest existing ancestor with every
    /// link resolved by the system, as a read or a write would resolve it,
    /// and the names below that ancestor as written, which is a file about to
    /// be written. A missing name that is itself a link is followed, because
    /// writing through a dangling link creates its target. Nil for a relative
    /// path, for a walk the system refuses (a loop of links, a file where a
    /// directory should be, a directory it may not search), and for missing
    /// names that climb with `..`, which name no place.
    static func resolved(_ path: String) -> String? {
        resolved(path, links: 0)
    }

    private static func resolved(_ path: String, links: Int) -> String? {
        guard (path as NSString).isAbsolutePath, links <= maximumLinks else { return nil }

        var existing = path
        var missing: [String] = []
        while true {
            let real = realPath(existing)
            if let resolved = real.resolved {
                guard !missing.contains("..") else { return nil }

                return missing.reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
            }
            guard real.failure == ENOENT else { return nil }

            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: existing) {
                let parent = (existing as NSString).deletingLastPathComponent
                let landing = (target as NSString).isAbsolutePath ? target : (parent as NSString).appendingPathComponent(target)
                return resolved(([landing] + missing).joined(separator: "/"), links: links + 1)
            }
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
    }

    /// `realpath(3)`, with why it failed read at once, before releasing the
    /// path's C string can touch `errno`.
    private static func realPath(_ path: String) -> (resolved: String?, failure: Int32) {
        path.withCString { pointer in
            guard let real = realpath(pointer, nil) else { return (nil, errno) }
            defer { free(real) }

            return (String(cString: real), 0)
        }
    }

    /// The links a resolution follows before it gives up, the system's own
    /// bound (`MAXSYMLINKS`).
    private static let maximumLinks = 32
}
