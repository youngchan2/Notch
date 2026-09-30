import Foundation

func runCodexReadStateChecks(_ check: (Bool, String) -> Void) {
    let date = Date(timeIntervalSince1970: 2000)
    let first = "11111111-1111-4111-8111-111111111111"
    let second = "22222222-2222-4222-8222-222222222222"
    let host = "remote-ssh-discovered:example"
    let hostKey = host + ":" + String(repeating: "a", count: 64)
    func data(_ unread: [String], identity: String = "account-a", version: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": [
            "version": version, "unreadByIdentity": [identity: [hostKey: unread]]
        ]])
    }
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notchwave-read-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        func save(_ bytes: Data, at time: Date) throws {
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
        }
        let snapshot = CodexReadSnapshot.decode(try data([first]), modifiedAt: date)!
        check(snapshot.state(session: first, hostID: host)?.unread == true, "Unread state matches the original remote host")
        check(snapshot.state(session: second, hostID: host)?.unread == false, "Known-host read state distinguishes individual conversations")
        check(snapshot.state(session: first, hostID: "local") == nil, "A different host cannot clear an alert")
        check(CodexReadSnapshot.decode(try data([], version: 2), modifiedAt: date) == nil, "Unknown storage versions do not acknowledge notifications")
        check(CodexReadSnapshot.decode(Data("{}".utf8), modifiedAt: date) == nil, "Missing read-state data is not a read receipt")
        let ambiguous = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": [
            "version": 1, "unreadByIdentity": ["account-a": [hostKey: [first]], "account-b": [hostKey: [String]()]]
        ]])
        check(CodexReadSnapshot.decode(ambiguous, modifiedAt: date)?.state(session: first, hostID: host) == nil, "Ambiguous accounts preserve notifications")
        var completed = AIEvent(provider: .codex, session: first, kind: .completed, project: "Read test", tool: "", createdAt: date, targetBundleID: AIProvider.codex.bundleID)
        completed.hostID = host
        var other = completed; other.id = UUID(); other.session = second
        var approval = completed; approval.id = UUID(); approval.session = "33333333-3333-4333-8333-333333333333"; approval.kind = .permission
        let monitor = CodexReadStateMonitor(file: file)
        check(monitor.readEventIDs(in: [completed], now: date).isEmpty, "A missing state file leaves new notifications visible")
        try save(data([first, second]), at: date.addingTimeInterval(1))
        check(monitor.readEventIDs(in: [completed, other, approval], now: date.addingTimeInterval(1)).isEmpty, "Unread completions stay in the queue")
        try save(data([second]), at: date.addingTimeInterval(2))
        let read = monitor.readEventIDs(in: [completed, other, approval], now: date.addingTimeInterval(2))
        check(read == [completed.id], "Reading one conversation dismisses only that completion")
        var queue = AIAlertQueue()
        queue.receive(completed, now: date, keepCodexVisible: true)
        for id in read { queue.dismiss(id) }
        check(queue.items.isEmpty && queue.banner == nil && queue.idleCodexAlert == nil, "Read completion disappears from history, banner, idle capsule, and stored badge")
        queue.tick(now: date.addingTimeInterval(10))
        check(queue.banner == nil, "A read completion cannot reappear from the waiting queue")
        var pendingQueue = AIAlertQueue()
        pendingQueue.receive(approval, now: date, keepCodexVisible: true)
        for id in read { pendingQueue.dismiss(id) }
        check(pendingQueue.pendingCount == 1, "Viewing a chat never approves or hides its pending permission request")

        let quick = CodexReadStateMonitor(file: file)
        try save(data([]), at: date.addingTimeInterval(-1))
        check(quick.readEventIDs(in: [completed], now: date.addingTimeInterval(5)).isEmpty, "Old read state cannot clear a newer completion")
        try save(data([]), at: date.addingTimeInterval(6))
        check(quick.readEventIDs(in: [completed], now: date.addingTimeInterval(6)).isEmpty, "A fast read waits briefly for delayed unread writes")
        check(quick.readEventIDs(in: [completed], now: date.addingTimeInterval(9)) == [completed.id], "A fresh stable read handles visits between polling intervals")

        let identity = CodexReadStateMonitor(file: file)
        try save(data([first]), at: date.addingTimeInterval(10))
        _ = identity.readEventIDs(in: [completed], now: date.addingTimeInterval(10))
        try save(data([], identity: "account-b"), at: date.addingTimeInterval(11))
        check(identity.readEventIDs(in: [completed], now: date.addingTimeInterval(15)).isEmpty, "Switching accounts does not clear a previous account's notification")
        check(identity.readEventIDs(in: [completed], now: date.addingTimeInterval(20)).isEmpty, "Account changes cannot become an inferred read after the delay")

        let broken = CodexReadStateMonitor(file: file)
        try save(data([first]), at: date.addingTimeInterval(21))
        _ = broken.readEventIDs(in: [completed], now: date.addingTimeInterval(21))
        try save(Data("{partial".utf8), at: date.addingTimeInterval(22))
        check(broken.readEventIDs(in: [completed], now: date.addingTimeInterval(22)).isEmpty, "Partial state writes preserve notifications")
        let finalBytes = try data([])
        try save(finalBytes, at: date.addingTimeInterval(23))
        check(broken.readEventIDs(in: [completed], now: date.addingTimeInterval(23)) == [completed.id], "Read-state watching recovers after an atomic file replacement")
        var newer = completed; newer.id = UUID(); newer.createdAt = date.addingTimeInterval(24)
        check(broken.readEventIDs(in: [newer], now: date.addingTimeInterval(25)).isEmpty, "A new turn does not inherit the previous turn's acknowledgement")
        var preview = completed; preview.preview = true
        var claude = completed; claude.provider = .claude
        check(broken.readEventIDs(in: [approval, preview, claude], now: date.addingTimeInterval(30)).isEmpty, "Only real Codex completion notifications follow Codex read markers")
        check(try Data(contentsOf: file) == finalBytes, "Read monitoring never rewrites Codex state")
    } catch { fatalError("Codex read-state checks failed: \(error)") }
}
