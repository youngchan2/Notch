import Foundation

/// Codex's saved read markers are scoped by account and execution host.
/// Missing state is unknown; it must never mean that every chat was read.
struct CodexReadSnapshot {
    struct Scope: Hashable {
        let identity: String
        let executionHost: String
    }
    struct Entry {
        let scope: Scope
        let hostID: String
        let unread: Set<String>
    }
    let entries: [Entry]
    let modifiedAt: Date

    static func decode(_ data: Data, modifiedAt: Date) -> CodexReadSnapshot? {
        guard data.count <= 4_194_304,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = root["electron-thread-read-state-v1"] as? [String: Any],
              state["version"] as? Int == 1,
              let identities = state["unreadByIdentity"] as? [String: [String: [String]]] else { return nil }
        var entries: [Entry] = []
        for (identity, hosts) in identities {
            for (executionHost, ids) in hosts {
                guard let separator = executionHost.lastIndex(of: ":") else { continue }
                let digest = executionHost[executionHost.index(after: separator)...]
                guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }),
                      let host = CodexThreadMetadata.validHost(String(executionHost[..<separator])),
                      ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { continue }
                entries.append(Entry(scope: Scope(identity: identity, executionHost: executionHost),
                                     hostID: host, unread: Set(ids.map { $0.lowercased() })))
            }
        }
        return CodexReadSnapshot(entries: entries, modifiedAt: modifiedAt)
    }

    func state(session: String, hostID: String) -> (scope: Scope, unread: Bool)? {
        guard let id = UUID(uuidString: session)?.uuidString.lowercased() else { return nil }
        let matches = entries.filter { $0.hostID == hostID }
        // Multiple accounts or host generations require a confirmed owner; retain the alert.
        guard matches.count == 1, let entry = matches.first else { return nil }
        return (entry.scope, entry.unread.contains(id))
    }
}

final class CodexReadStateMonitor {
    private struct Stamp: Equatable {
        let modified: Date
        let size: UInt64
        let inode: UInt64
    }
    private struct Observation {
        var scope: CodexReadSnapshot.Scope?
        var sawUnread = false
        var allowInitialRead = true
        var readSince: Date?
    }
    private let file: URL
    private var stamp: Stamp?
    private var cached: CodexReadSnapshot?
    private var observations: [UUID: Observation] = [:]

    init(file: URL = LocalTool.codexHome().appendingPathComponent(".codex-global-state.json")) { self.file = file }
    func reset() { stamp = nil; cached = nil; observations.removeAll() }

    func readEventIDs(in events: [AIEvent], now: Date = Date()) -> Set<UUID> {
        let completed = events.filter { $0.provider == .codex && $0.kind == .completed && !$0.preview }
        let ids = Set(completed.map(\.id))
        observations = observations.filter { ids.contains($0.key) }
        guard !completed.isEmpty, let snapshot = snapshot() else { return [] }
        var read: Set<UUID> = []
        for event in completed {
            var observation = observations[event.id] ?? Observation()
            guard let host = event.hostID, let state = snapshot.state(session: event.session, hostID: host) else {
                // Logout, reconnect, or unknown host must not acknowledge a different scope.
                if observation.scope != nil { observation = Observation(allowInitialRead: false) }
                observations[event.id] = observation
                continue
            }
            if let prior = observation.scope, prior != state.scope {
                observation = Observation(allowInitialRead: false)
            }
            observation.scope = state.scope
            if state.unread {
                if snapshot.modifiedAt >= event.createdAt { observation.sawUnread = true }
                observation.readSince = nil
            } else if observation.sawUnread && snapshot.modifiedAt >= event.createdAt {
                read.insert(event.id)
            } else if observation.allowInitialRead && snapshot.modifiedAt >= event.createdAt {
                // A very quick visit can occur between polls. Accept only fresh saved state,
                // after a short stable-read interval so delayed completion writes can settle.
                if observation.readSince == nil { observation.readSince = now }
                if now.timeIntervalSince(event.createdAt) >= 3,
                   now.timeIntervalSince(observation.readSince!) >= 2 { read.insert(event.id) }
            } else { observation.readSince = nil }
            observations[event.id] = observation
        }
        return read
    }

    private func snapshot() -> CodexReadSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber, size.uint64Value <= 4_194_304,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        let current = Stamp(modified: modified, size: size.uint64Value, inode: inode.uint64Value)
        if current == stamp { return cached }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_194_305) else { return nil }
        let result = CodexReadSnapshot.decode(data, modifiedAt: modified)
        stamp = current; cached = result
        return result
    }
}
