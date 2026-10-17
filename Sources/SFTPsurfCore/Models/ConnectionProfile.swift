import Foundation

public enum RemoteProtocolKind: String, Codable, CaseIterable, Sendable {
    case sftp
    case ftp

    public var displayName: String {
        switch self {
        case .sftp: return "SFTP"
        case .ftp: return "FTP"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .sftp: return 22
        case .ftp: return 21
        }
    }
}

/// Everything needed to open a session, minus the secret.
public struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var nickname: String
    public var kind: RemoteProtocolKind
    public var host: String
    public var port: Int?
    public var username: String
    public var authMethod: AuthMethod
    public var initialPath: String

    // SFTP-only
    /// `user@bastion` style jump host, forwarded to `ssh -J`.
    public var proxyJump: String?
    /// Extra raw options passed straight to `ssh`, one per element.
    public var sshOptions: [String]

    // FTP-only
    public var ftpPassive: Bool
    public var ftpUTF8: Bool

    /// Set whenever a session is opened, so the sidebar can order by recency.
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        nickname: String = "",
        kind: RemoteProtocolKind = .sftp,
        host: String = "",
        port: Int? = nil,
        username: String = "",
        authMethod: AuthMethod = .password,
        initialPath: String = "",
        proxyJump: String? = nil,
        sshOptions: [String] = [],
        ftpPassive: Bool = true,
        ftpUTF8: Bool = true,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.nickname = nickname
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.initialPath = initialPath
        self.proxyJump = proxyJump
        self.sshOptions = sshOptions
        self.ftpPassive = ftpPassive
        self.ftpUTF8 = ftpUTF8
        self.lastUsedAt = lastUsedAt
    }

    public var effectivePort: Int { port ?? kind.defaultPort }

    /// Label shown in the sidebar.
    public var displayName: String {
        if !nickname.isEmpty { return nickname }
        if host.isEmpty { return "New Connection" }
        let user = username.isEmpty ? "" : "\(username)@"
        return "\(user)\(host)"
    }

    public var subtitle: String {
        "\(kind.displayName) · \(username.isEmpty ? "" : username + "@")\(host):\(effectivePort)"
    }
}

public enum AuthMethod: Codable, Hashable, Sendable {
    /// Password read from the keychain (or prompted per-session).
    case password
    /// An explicit private key file, passed to `ssh -i`.
    case privateKey(path: String)
    /// Let `ssh` use the agent and the user's default identity files.
    case agentAndDefaults

    public var displayName: String {
        switch self {
        case .password: return "Password"
        case .privateKey: return "Private Key File"
        case .agentAndDefaults: return "SSH Agent / Default Keys"
        }
    }

    /// FTP has no key-based auth, so profiles of that kind always use this.
    public static func sanitized(_ method: AuthMethod, for kind: RemoteProtocolKind) -> AuthMethod {
        kind == .ftp ? .password : method
    }
}

/// How a session should authenticate for a single connect attempt.
public struct Credential: Sendable {
    public var password: String?
    public var passphrase: String?

    public init(password: String? = nil, passphrase: String? = nil) {
        self.password = password
        self.passphrase = passphrase
    }

    public static let none = Credential()
}
