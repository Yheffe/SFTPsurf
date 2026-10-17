import Foundation

public enum Bootstrap {
    /// A closed peer turns into `SIGPIPE`, which would kill the app outright.
    /// The transports already surface `EPIPE` as a normal error, so ignoring the
    /// signal is what turns a dropped connection into a friendly message.
    public static func configureProcess() {
        signal(SIGPIPE, SIG_IGN)
    }
}

/// POSIX-style path helpers. Remote paths always use `/` regardless of platform.
public enum RemotePath {
    /// Joins a directory and a name without doubling separators.
    public static func join(_ directory: String, _ name: String) -> String {
        if directory.isEmpty { return "/" + name }
        if name.isEmpty { return normalize(directory) }
        if directory.hasSuffix("/") { return normalize(directory + name) }
        return normalize(directory + "/" + name)
    }

    /// Removes redundant separators and trailing slashes (but keeps the root).
    public static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        var result = path
        while result.contains("//") {
            result = result.replacingOccurrences(of: "//", with: "/")
        }
        if result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// The parent directory, or nil when already at the root.
    public static func parent(of path: String) -> String? {
        let normalized = normalize(path)
        guard normalized != "/" else { return nil }
        guard let index = normalized.lastIndex(of: "/") else { return "/" }
        if index == normalized.startIndex { return "/" }
        return String(normalized[normalized.startIndex..<index])
    }

    public static func lastComponent(of path: String) -> String {
        let normalized = normalize(path)
        guard let index = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: index)...])
    }

    /// Resolves `.` and `..` segments.
    public static func resolve(_ path: String, relativeTo base: String) -> String {
        let combined = path.hasPrefix("/") ? path : join(base, path)
        var stack: [String] = []
        for component in components(combined) {
            switch component {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(component)
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    /// Splits a path into its meaningful components.
    public static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// True when `child` is `parent` or lives underneath it.
    public static func isDescendant(_ child: String, of parent: String) -> Bool {
        let normalizedParent = normalize(parent)
        let normalizedChild = normalize(child)
        if normalizedChild == normalizedParent { return true }
        return normalizedChild.hasPrefix(normalizedParent == "/" ? "/" : normalizedParent + "/")
    }
}
