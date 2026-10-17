import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import SFTPsurfCore

/// Columns the browser can sort by.
public enum SortColumn: String, CaseIterable {
    case name
    case size
    case modified
    case kind

    public var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Modified"
        case .kind: return "Kind"
        }
    }
}

/// Lifecycle of the remote session.
public enum SessionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
}

/// A message worth interrupting the user for.
public struct AlertPayload: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
}

/// Symbols used consistently across both panes.
public enum EntryIcon {
    public static func symbol(isDirectory: Bool, isSymlink: Bool, name: String) -> String {
        if isSymlink { return "arrow.triangle.turn.up.right.diamond" }
        if isDirectory { return "folder.fill" }

        switch (name as NSString).pathExtension.lowercased() {
        case "txt", "md", "rtf", "log": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "svg": return "photo"
        case "mp3", "wav", "aac", "flac", "m4a": return "waveform"
        case "mp4", "mov", "avi", "mkv", "webm": return "film"
        case "zip", "gz", "tar", "bz2", "xz", "7z", "rar": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "swift", "py", "js", "ts", "go", "rs", "c", "h", "cpp", "java", "rb", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "app": return "app"
        case "dmg", "iso": return "externaldrive"
        case "json", "yml", "yaml", "toml", "xml", "plist", "ini": return "curlybraces"
        default: return "doc"
        }
    }
}

/// Formats listing details the way the two panes show them.
public enum ListingFormatter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    public static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return dateFormatter.string(from: value)
    }

    public static func size(bytes: Int64, isDirectory: Bool) -> String {
        if isDirectory { return "—" }
        return ByteFormatter.string(bytes)
    }

    public static func kind(name: String, isDirectory: Bool, isSymlink: Bool) -> String {
        if isSymlink { return "Alias" }
        if isDirectory { return "Folder" }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "Document" : "\(ext.uppercased()) file"
    }
}
