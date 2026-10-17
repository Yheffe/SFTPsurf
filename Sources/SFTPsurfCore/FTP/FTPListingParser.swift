import Foundation

/// Parses the two directory listing formats FTP servers actually send.
public enum FTPListingParser {
    // MARK: - MLSD (RFC 3659)

    /// Parses a `MLSD` line such as
    /// `type=file;size=1234;modify=20240112123456; name with spaces.txt`
    public static func parseMLSD(_ line: String, parent: String) -> RemoteEntry? {
        guard let separator = line.firstIndex(of: " ") else { return nil }
        let facts = String(line[line.startIndex..<separator])
        let name = String(line[line.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        var values: [String: String] = [:]
        for fact in facts.split(separator: ";") {
            guard let equals = fact.firstIndex(of: "=") else { continue }
            values[String(fact[fact.startIndex..<equals]).lowercased()] =
                String(fact[fact.index(after: equals)...])
        }

        let type = values["type"]?.lowercased() ?? ""
        // These two describe the listed directory itself, not its contents.
        if type == "cdir" || type == "pdir" { return nil }

        let isDirectory = type == "dir"
        let isSymlink = type == "os.unix=slink" || type == "os.unix=symlink"

        var unixMode: UInt32?
        if let permissions = values["unix.mode"], let octal = UInt32(permissions, radix: 8) {
            // MLSD gives only the permission bits, so re-attach the file type.
            unixMode = octal | (isDirectory ? RemoteEntry.directoryModeBit
                                            : (isSymlink ? RemoteEntry.symlinkModeBit : 0o100000))
        }

        return RemoteEntry(
            name: name,
            path: RemotePath.join(parent, name),
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: Int64(values["size"] ?? "0") ?? 0,
            modified: parseMLSDDate(values["modify"]),
            permissions: unixMode,
            owner: values["unix.owner"],
            group: values["unix.group"]
        )
    }

    /// MLSD timestamps are `YYYYMMDDHHMMSS` in UTC, with fractional seconds optional.
    public static func parseMLSDDate(_ value: String?) -> Date? {
        guard let value, value.count >= 14 else { return nil }
        let digits = value.prefix(14)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(digits))
    }

    // MARK: - Unix `ls -l` style listings

    /// Matches the classic `ls -l` columns. Owner and group may be absent on
    /// some servers, so they are optional.
    private static let unixPattern = try? NSRegularExpression(
        pattern: "^([-dlbcpsD])([rwxstST-]{9})[.+]?\\s+(\\d+)\\s+(\\S+)\\s+(\\S+)\\s+(\\d+)\\s+(\\S+\\s+\\d{1,2}\\s+(?:\\d{4}|\\d{1,2}:\\d{2}(?::\\d{2})?))\\s+(.*)$"
    )

    public static func parseUnix(_ line: String, parent: String) -> RemoteEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("total ") else { return nil }
        guard let pattern = unixPattern else { return nil }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = pattern.firstMatch(in: trimmed, range: range) else { return nil }

        func group(_ index: Int) -> String? {
            guard let matchRange = Range(match.range(at: index), in: trimmed) else { return nil }
            return String(trimmed[matchRange])
        }

        guard let typeCharacter = group(1)?.first,
              let permissionLetters = group(2),
              let sizeText = group(6),
              let dateText = group(7),
              var name = group(8) else { return nil }

        let isDirectory = typeCharacter == "d"
        let isSymlink = typeCharacter == "l"

        // Symlinks read "name -> target"; the browser only needs the link itself.
        if isSymlink, let arrow = name.range(of: " -> ") {
            name = String(name[name.startIndex..<arrow.lowerBound])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        return RemoteEntry(
            name: name,
            path: RemotePath.join(parent, name),
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: Int64(sizeText) ?? 0,
            modified: parseUnixDate(dateText),
            permissions: modeBits(type: typeCharacter, letters: permissionLetters),
            owner: group(4),
            group: group(5)
        )
    }

    /// Rebuilds numeric mode bits from the symbolic form.
    public static func modeBits(type: Character, letters: String) -> UInt32 {
        let typeBits: UInt32
        switch type {
        case "d": typeBits = RemoteEntry.directoryModeBit
        case "l": typeBits = RemoteEntry.symlinkModeBit
        default: typeBits = 0o100000
        }

        // What each of the nine slots contributes on its own.
        let widths: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        // setuid, setgid and sticky share slots with the owner, group and other
        // execute bits — slots 2, 5 and 8 respectively.
        let specials: [UInt32] = [0, 0, 0o4000, 0, 0, 0o2000, 0, 0, 0o1000]

        var bits: UInt32 = typeBits
        for (offset, character) in letters.enumerated() where offset < widths.count {
            switch character {
            case "-":
                continue
            // Lowercase s/t mean "special bit *and* execute".
            case "s", "t":
                bits |= widths[offset] | specials[offset]
            // Uppercase S/T mean the special bit without execute.
            case "S", "T":
                bits |= specials[offset]
            default:
                bits |= widths[offset]
            }
        }
        return bits
    }

    private static let monthNames = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// `ls` shows a time for recent files and a year for older ones, and omits
    /// the year entirely for the current one.
    public static func parseUnixDate(_ text: String, now: Date = Date()) -> Date? {
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        guard let month = monthNames[parts[0].lowercased()] else { return nil }
        let day = Int(parts[1]) ?? 1

        var hour = 0
        var minute = 0
        var second = 0
        var year: Int

        if parts.count >= 3, parts[2].contains(":") {
            let clock = parts[2].split(separator: ":").map { Int($0) ?? 0 }
            hour = clock.count > 0 ? clock[0] : 0
            minute = clock.count > 1 ? clock[1] : 0
            second = clock.count > 2 ? clock[2] : 0
            // No year given, so it is within the last twelve months. Anything in
            // the future by more than a day belongs to the previous year.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let currentYear = calendar.component(.year, from: now)
            let candidate = makeDate(year: currentYear, month: month, day: day, hour: hour, minute: minute, second: second)
            if let candidate, candidate.timeIntervalSince(now) > 24 * 3600 {
                year = currentYear - 1
            } else {
                return candidate
            }
        } else {
            year = Int(parts[2]) ?? 1970
        }

        return makeDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    private static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }
}
