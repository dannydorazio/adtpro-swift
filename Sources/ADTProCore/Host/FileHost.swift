import Foundation

/// The host side of the file system as the Apple sees it: a working directory
/// that the client can list and change, and name resolution for disk images.
///
/// Apple clients send names in upper case, so on case-sensitive file systems
/// names and paths are matched case-insensitively when an exact match is absent.
public final class FileHost: @unchecked Sendable {
    private let lock = NSLock()
    private var _workingDirectory: String
    private let fileManager = FileManager.default

    public init(workingDirectory: String) {
        let standardized = (workingDirectory as NSString).expandingTildeInPath
        _workingDirectory = FileHost.withTrailingSlash(URL(fileURLWithPath: standardized).standardizedFileURL.path)
    }

    /// Absolute path of the working directory, always ending in "/".
    public var workingDirectory: String {
        lock.withLock { _workingDirectory }
    }

    static func withTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Change the working directory. Relative paths are taken from the current
    /// working directory. Returns false (and changes nothing) when the result is
    /// not an existing directory.
    @discardableResult
    public func changeDirectory(_ request: String) -> Bool {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !trimmed.isEmpty else { return false }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let candidate: String
        if expanded.hasPrefix("/") {
            candidate = expanded
        } else {
            candidate = workingDirectory + expanded
        }
        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = isDirectory(standardized) ? standardized : resolveCaseInsensitively(standardized)
        guard let resolved, isDirectory(resolved) else { return false }
        lock.withLock { _workingDirectory = FileHost.withTrailingSlash(resolved) }
        return true
    }

    /// Visible entries of the working directory, sorted case-insensitively.
    /// `pattern` may use `*` and `?` wildcards and is matched case-insensitively.
    /// Returns nil when the directory cannot be read.
    public func listing(matching pattern: String? = nil) -> [String]? {
        guard let names = try? fileManager.contentsOfDirectory(atPath: workingDirectory) else { return nil }
        var visible = names.filter { !$0.hasPrefix(".") }
        if let pattern, !pattern.isEmpty {
            visible = visible.filter { FileHost.wildcard(pattern, matches: $0) }
        }
        return visible.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func wildcard(_ pattern: String, matches name: String) -> Bool {
        let p = Array(pattern.uppercased()), s = Array(name.uppercased())
        var pi = 0, si = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                pi += 1; si += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi; mark = si; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Resolve a name the Apple asked for: first relative to the working
    /// directory, then as given (absolute, or relative to the process). Falls
    /// back to case-insensitive matching. Returns nil if nothing exists.
    public func resolveExisting(_ name: String) -> String? {
        let candidates = name.hasPrefix("/") ? [name] : [workingDirectory + name, name]
        for c in candidates where fileManager.fileExists(atPath: c) { return c }
        for c in candidates {
            if let r = resolveCaseInsensitively(c) { return r }
        }
        return nil
    }

    /// Path for a new file in the working directory.
    public func pathForNewFile(_ name: String) -> String {
        name.hasPrefix("/") ? name : workingDirectory + name
    }

    /// Walk the path component by component, matching each case-insensitively.
    func resolveCaseInsensitively(_ path: String) -> String? {
        let absolute = path.hasPrefix("/") ? path : fileManager.currentDirectoryPath + "/" + path
        var current = "/"
        for component in absolute.split(separator: "/").map(String.init) {
            if component == "." { continue }
            if component == ".." { current = (current as NSString).deletingLastPathComponent; continue }
            let exact = (current as NSString).appendingPathComponent(component)
            if fileManager.fileExists(atPath: exact) { current = exact; continue }
            guard let entries = try? fileManager.contentsOfDirectory(atPath: current),
                  let match = entries.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
            else { return nil }
            current = (current as NSString).appendingPathComponent(match)
        }
        return current
    }
}
