import Foundation

/// Local hooks cannot report runs hosted over SSH. The desktop app records the
/// same completion signal for local and remote chats; read only its routing IDs.
/// This is a compatibility fallback, not a public Codex API. Never read transcripts.
final class CodexCompletionMonitor {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex", isDirectory: true)
    }
    private struct Cursor {
        var offset: UInt64
        var inode: UInt64
        var partial = Data()
        var discardingLongLine = false
    }
    private var cursors: [URL: Cursor] = [:]
    private var startedAt: Date?
    private var nextDiscovery = Date.distantPast
    private let directory: URL
    private let discover: (() -> [URL])?
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(directory: URL = CodexCompletionMonitor.directory, discover: (() -> [URL])? = nil) {
        self.directory = directory; self.discover = discover
    }

    static func event(from line: String) -> AIEvent? {
        let marker = " info [electron-message-handler] [desktop-notifications] received turn-complete "
        guard let range = line.range(of: marker), line.utf8.count <= 16_384,
              let date = timestamp.date(from: String(line[..<range.lowerBound])) else { return nil }
        let fields = line[range.upperBound...].split(separator: " ").reduce(into: [String: String]()) { result, field in
            let pair = field.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        guard let session = fields["conversationId"], UUID(uuidString: session) != nil,
              let turn = fields["turnId"].flatMap(UUID.init(uuidString:)) else { return nil }
        return AIEvent(id: turn, provider: .codex, session: session, kind: .completed,
                       project: "Codex 대화", tool: "", createdAt: date, targetBundleID: AIProvider.codex.bundleID)
    }

    func reset() { cursors.removeAll(); startedAt = nil; nextDiscovery = .distantPast }

    func poll(now: Date = Date()) -> [AIEvent] {
        let firstPoll = startedAt == nil
        if firstPoll { startedAt = now }
        if now >= nextDiscovery {
            let files = discover?() ?? currentFiles(now: now)
            for file in files where cursors[file] == nil {
                guard let info = Self.fileInfo(file) else { continue }
                // Establish an EOF baseline on launch; do not replay old completions.
                cursors[file] = Cursor(offset: firstPoll ? info.size : 0, inode: info.inode)
            }
            if cursors.count > 16 {
                let keep = Set(files)
                cursors = cursors.filter { keep.contains($0.key) }
            }
            nextDiscovery = now.addingTimeInterval(5)
        }
        guard !firstPoll else { return [] }
        var events: [AIEvent] = []
        for file in Array(cursors.keys) {
            guard var cursor = cursors[file],
                  let info = Self.fileInfo(file),
                  let handle = try? FileHandle(forReadingFrom: file) else {
                cursors.removeValue(forKey: file); continue
            }
            defer { try? handle.close() }
            if info.size < cursor.offset || info.inode != cursor.inode {
                cursor = Cursor(offset: 0, inode: info.inode)
            }
            do {
                try handle.seek(toOffset: cursor.offset)
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                cursor.offset += UInt64(data.count)
                for byte in data {
                    if byte == 10 {
                        if !cursor.discardingLongLine,
                           let line = String(data: cursor.partial, encoding: .utf8),
                           let event = Self.event(from: line), event.createdAt >= startedAt!,
                           now.timeIntervalSince(event.createdAt) < 60,
                           event.createdAt <= now.addingTimeInterval(5) { events.append(event) }
                        cursor.partial.removeAll(keepingCapacity: true)
                        cursor.discardingLongLine = false
                    } else if !cursor.discardingLongLine {
                        if cursor.partial.count < 16_384 { cursor.partial.append(byte) }
                        else { cursor.partial.removeAll(keepingCapacity: true); cursor.discardingLongLine = true }
                    }
                }
                cursors[file] = cursor
            } catch { continue }
        }
        return events.sorted { $0.createdAt < $1.createdAt }
    }

    private static func fileInfo(_ file: URL) -> (size: UInt64, inode: UInt64)? {
        // URL resourceValues caches file sizes on retained URLs. Use fresh stat
        // information so appended data cannot look like truncation on the next poll.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return (size.uint64Value, inode.uint64Value)
    }

    private func currentFiles(now: Date) -> [URL] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/dd"
        var files: [URL] = []
        for date in [now, now.addingTimeInterval(-86400)] {
            let day = directory.appendingPathComponent(formatter.string(from: date), isDirectory: true)
            files += (try? FileManager.default.contentsOfDirectory(at: day, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        return Array(files.filter { $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("codex-desktop-") && $0.lastPathComponent.contains("-t0-") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }.prefix(8))
    }
}
