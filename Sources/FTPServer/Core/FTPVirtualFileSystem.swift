import Foundation

/// 目录项元数据，供 LIST / NLST / MLSD 三种列举格式共用。
struct FSEntry {
    let name: String
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modified: Date
    let posixPermissions: Int
    let owner: String
    let group: String
}

struct FTPPermissions: Equatable {
    var canDownload: Bool
    var canUpload: Bool
    var canDelete: Bool
    var canCreateDirectory: Bool

    static let readOnly = FTPPermissions(canDownload: true, canUpload: false,
                                         canDelete: false, canCreateDirectory: false)
}

/// 以某个根目录为边界的虚拟文件系统。
///
/// 安全模型：客户端提供的路径先被规范化为虚拟绝对路径（逐段消除 `.` / `..`），
/// 任何试图越过根目录的 `..` 直接拒绝；随后再做一次符号链接解析后的包含性校验，
/// 防止通过根目录内的软链接逃逸到文件系统其他位置。
struct FTPVirtualFileSystem {
    let rootURL: URL

    init(rootPath: String) {
        let expanded = (rootPath as NSString).expandingTildeInPath
        rootURL = URL(fileURLWithPath: expanded, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    // MARK: - 路径规范化

    func normalize(_ path: String, relativeTo cwd: String) throws -> String {
        var components: [String] = []
        if !path.hasPrefix("/") {
            components = cwd.split(separator: "/").map(String.init)
        }
        for part in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch part {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { throw FTPError.escapesRoot }
                components.removeLast()
            default:
                guard !part.contains("\0") else { throw FTPError.invalidPath }
                components.append(part)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// 规范化虚拟路径到磁盘 URL，并做符号链接包含性校验。
    func fileURL(for virtualPath: String) -> URL {
        if virtualPath == "/" || virtualPath.isEmpty { return rootURL }
        var url = rootURL
        for component in virtualPath.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }

    func ensureInsideRoot(_ url: URL) throws {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = rootURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if target == root || target.hasPrefix(prefix) { return }
        throw FTPError.escapesRoot
    }

    /// 目标自身若是符号链接，必须确认它指向的位置仍在根目录之内。
    ///
    /// 读路径靠 `ensureInsideRoot` 解析链接即可拦住逃逸，但**写路径校验的是父目录**：
    /// 根目录里一个指向外部的软链接，其父目录就是根目录本身，校验会顺利通过，
    /// 随后 `STOR` / `APPE` 顺链写入根目录之外，覆盖共享范围外任意可写文件。
    /// 因此写入前必须单独校验目标自身。
    ///
    /// `attributesOfItem` 不跟随符号链接，悬空链接同样能被识别出来。
    func ensureTargetNotEscapingLink(_ url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeSymbolicLink else {
            return
        }
        // 链接指向仍然存在的文件：解析后必须落在根目录内
        try ensureInsideRoot(url)
        // 悬空链接解析不出来，只能直接读链接目标再判一次；相对目标要基于链接所在目录展开
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            let base = url.deletingLastPathComponent()
            let target = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : base.appendingPathComponent(destination)
            try ensureInsideRoot(target.standardizedFileURL)
        }
    }

    /// 读取路径：目标必须存在于根目录之内。
    func resolveForRead(_ path: String, relativeTo cwd: String) throws -> URL {
        let normalized = try normalize(path, relativeTo: cwd)
        let url = fileURL(for: normalized)
        try ensureInsideRoot(url)
        return url
    }

    /// 写入路径：目标是新文件时允许不存在，但其父目录必须存在且位于根目录之内。
    func resolveForWrite(_ path: String, relativeTo cwd: String) throws -> URL {
        let normalized = try normalize(path, relativeTo: cwd)
        guard normalized != "/" else { throw FTPError.permissionDenied("不能覆盖根目录") }
        let url = fileURL(for: normalized)
        // 已存在的目标若是指向根目录之外的软链接，必须在这里拦下
        try ensureTargetNotEscapingLink(url)
        let parent = url.deletingLastPathComponent()
        try ensureInsideRoot(parent)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else { throw FTPError.notFound }
        return url
    }

    // MARK: - 元数据

    func entry(for url: URL, name: String? = nil) throws -> FSEntry {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType ?? .typeUnknown
        let isSymbolic = (type == .typeSymbolicLink)

        let isDirectory: Bool
        if isSymbolic {
            var directoryFlag: ObjCBool = false
            manager.fileExists(atPath: url.path, isDirectory: &directoryFlag)
            isDirectory = directoryFlag.boolValue
        } else {
            isDirectory = (type == .typeDirectory)
        }

        return FSEntry(
            name: name ?? url.lastPathComponent,
            url: url,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolic,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0),
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644,
            owner: (attributes[.ownerAccountName] as? String) ?? "ftp",
            group: (attributes[.groupOwnerAccountName] as? String) ?? "ftp"
        )
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
        return flag.boolValue
    }

    // MARK: - 目录枚举

    func list(_ virtualPath: String) throws -> [FSEntry] {
        let url = fileURL(for: virtualPath)
        try ensureInsideRoot(url)
        guard exists(url) else { throw FTPError.notFound }
        guard isDirectory(url) else { throw FTPError.notADirectory }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )) ?? []

        var entries: [FSEntry] = []
        entries.reserveCapacity(contents.count)
        for child in contents {
            let name = child.lastPathComponent
            if name == "." || name == ".." { continue }
            if let item = try? entry(for: child, name: name) { entries.append(item) }
        }
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    // MARK: - 列举格式

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                             "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func permissionString(_ mode: Int) -> String {
        let letters = ["r", "w", "x"]
        var text = ""
        for groupShift in [6, 3, 0] {
            for offset in 0..<3 {
                let bit = (mode >> (groupShift + (2 - offset))) & 1
                text += bit == 1 ? letters[offset] : "-"
            }
        }
        return text
    }

    static func listDateText(_ date: Date) -> String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let monthIndex = max(0, min(11, (parts.month ?? 1) - 1))
        let month = monthNames[monthIndex]
        let day = parts.day ?? 1
        let sixMonths: TimeInterval = 60 * 60 * 24 * 183
        if abs(date.timeIntervalSinceNow) < sixMonths {
            return String(format: "%@ %2d %02d:%02d", month, day, parts.hour ?? 0, parts.minute ?? 0)
        }
        return String(format: "%@ %2d  %04d", month, day, parts.year ?? 1970)
    }

    static func padRight(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func padLeft(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    static func listLine(for entry: FSEntry) -> String {
        let typeCharacter: String
        if entry.isSymbolicLink {
            typeCharacter = "l"
        } else if entry.isDirectory {
            typeCharacter = "d"
        } else {
            typeCharacter = "-"
        }
        let permissions = permissionString(entry.posixPermissions)
        let owner = padRight(entry.owner, 8)
        let group = padRight(entry.group, 8)
        let size = padLeft(String(entry.size), 10)
        let date = listDateText(entry.modified)
        var name = entry.name
        if entry.isSymbolicLink, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path) {
            name += " -> " + target
        }
        return "\(typeCharacter)\(permissions)    1 \(owner) \(group) \(size) \(date) \(name)"
    }

    static func listData(entries: [FSEntry]) -> Data {
        var text = ""
        text.reserveCapacity(entries.count * 80)
        for entry in entries { text += listLine(for: entry) + "\r\n" }
        return Data(text.utf8)
    }

    static func nlstData(entries: [FSEntry]) -> Data {
        var text = ""
        for entry in entries { text += entry.name + "\r\n" }
        return Data(text.utf8)
    }

    // MARK: - RFC 3659 MLSD / MLST

    static func utcTimestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02d",
                      parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    static func mlsdPermissions(isDirectory: Bool, permissions: FTPPermissions) -> String {
        if isDirectory {
            var text = "el"
            if permissions.canCreateDirectory { text += "cm" }
            if permissions.canDelete { text += "pf" }
            return text
        }
        var text = "r"
        if permissions.canUpload { text += "w" }
        if permissions.canDelete { text += "df" }
        return text
    }

    static func mlsdLine(for entry: FSEntry, permissions: FTPPermissions) -> String {
        var facts: [String] = []
        facts.append("type=\(entry.isDirectory ? "dir" : "file")")
        if entry.isDirectory {
            facts.append("sizd=\(max(1, entry.size / 512))")
        } else {
            facts.append("size=\(entry.size)")
        }
        facts.append("modify=\(utcTimestamp(entry.modified))")
        facts.append("UNIX.mode=\(String(format: "%04o", entry.posixPermissions))")
        facts.append("UNIX.owner=\(entry.owner)")
        facts.append("UNIX.group=\(entry.group)")
        facts.append("perm=\(mlsdPermissions(isDirectory: entry.isDirectory, permissions: permissions))")
        return facts.joined(separator: ";") + "; " + entry.name
    }

    static func mlsdData(entries: [FSEntry], permissions: FTPPermissions) -> Data {
        var text = ""
        text.reserveCapacity(entries.count * 96)
        for entry in entries { text += mlsdLine(for: entry, permissions: permissions) + "\r\n" }
        return Data(text.utf8)
    }
}
