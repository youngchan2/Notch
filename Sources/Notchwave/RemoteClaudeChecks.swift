import Foundation

@MainActor func runRemoteClaudeChecks(_ check: (Bool, String) -> Void) {
    let now = Date(timeIntervalSince1970: 10_000)
    let key = String(repeating: "a", count: 64)
    let id = UUID()
    let wire: [String: Any] = ["id": id.uuidString, "session": "same-session", "key": key,
        "hook": "Stop", "project": "한글 프로젝트", "tool": "", "created": now.timeIntervalSince1970, "can_attach": true]
    let one = RemoteClaude.event(wire, host: "nutella1", now: now)!
    let two = RemoteClaude.event(wire, host: "nutella2", now: now)!
    check(one.conversationLabel == "nutella1 · 한글 프로젝트", "Remote alert identifies its host and project")
    check(one.sessionKey != two.sessionKey, "Matching session IDs on different servers cannot clear each other's alerts")
    check(one.id == id && one.remoteSessionKey == key && one.openingAction == "tmux 열기", "Remote event preserves deduplication and tmux routing")
    check(one.openingBundleID == "com.mitchellh.ghostty", "SSH Claude opens Ghostty")
    check(RemoteClaude.connectionStatus(["type": "ready", "hooks_ready": true]) == "연결됨", "SSH ready only reports connected after hook registration is verified")
    check(RemoteClaude.connectionStatus(["type": "ready"]) == "알림 설정 확인 필요", "Legacy relay cannot claim hook registration is verified")
    check(RemoteClaude.connectionStatus(["type": "heartbeat", "hooks_ready": false]) == "알림 설정 확인 필요", "Remote hook removal becomes visible on heartbeat")
    check(RemoteClaude.connectionStatus(["type": "event"]) == nil, "Event messages do not overwrite connection health")
    check(RemoteClaude.event(wire, host: "-oProxyCommand=bad", now: now) == nil, "Remote host cannot inject SSH options")
    check(!RemoteClaude.validHost("host;touch /tmp/x") && !RemoteClaude.validHost("host\nother"), "Remote host rejects shell syntax")
    check(RemoteClaude.validHost("user@server.example") && RemoteClaude.validHost("nutella1"), "Standard SSH aliases and login names work")
    var bad = wire; bad["created"] = now.addingTimeInterval(-3601).timeIntervalSince1970
    check(RemoteClaude.event(bad, host: "nutella1", now: now) == nil, "Old remote events do not replay")
    bad["created"] = now.addingTimeInterval(61).timeIntervalSince1970
    check(RemoteClaude.event(bad, host: "nutella1", now: now) == nil, "Future remote timestamps are bounded")
    bad = wire; bad["key"] = "$(command)"
    check(RemoteClaude.event(bad, host: "nutella1", now: now) == nil, "Remote session reference cannot become a shell command")
    check(RemoteClaude.attachCommand(host: "nutella1", key: "../other") == nil, "Attach command rejects mailbox traversal")
    bad = wire; bad["can_attach"] = false
    check(RemoteClaude.event(bad, host: "nutella1", now: now)?.remoteSessionKey == nil, "Non-tmux tasks do not claim a tmux destination")
    var queue = AIAlertQueue()
    queue.receive(one, now: now); queue.receive(two, now: now)
    // Different UUIDs are normal on the servers; deliberately identical IDs deduplicate delivery.
    check(queue.items.count == 1, "Repeated remote delivery is idempotent")
    var other = two; other.id = UUID(); queue.receive(other, now: now)
    var resumed = one; resumed.id = UUID(); resumed.kind = .resumed; resumed.createdAt = now.addingTimeInterval(1)
    queue.receive(resumed, now: now.addingTimeInterval(1))
    check(queue.items.count == 1 && queue.items[0].remoteHost == "nutella2", "Resuming one SSH task only clears that task's alert")
    let frames = RemoteClaudeFrames()
    check(frames.append(Data("{\"test\": ".utf8)).isEmpty, "SSH JSON tolerates packet fragmentation")
    check(frames.append(Data("1}\n{}\n".utf8)).count == 2, "SSH JSON supports multiple frames in a packet")
    check(frames.append(Data(repeating: 65, count: 20000)).isEmpty, "SSH output buffering is bounded")
    check(frames.append(Data("\n{}\n".utf8)) == [Data("{}".utf8)], "Oversized SSH line is discarded without losing following messages")
    check(RemoteClaude.appleString("a\\b\"c") == "\"a\\\\b\\\"c\"", "AppleScript quoting preserves command literals")
    var selection = RemoteConnectionSelection(connected: ["nutella1", "nutella2"])
    check(!selection.hasChanges && selection.additions.isEmpty && selection.removals.isEmpty, "Existing SSH connections start checked without scheduling any changes")
    selection.toggle("h100-vla"); selection.toggle("kfold")
    check(selection.additions == ["h100-vla", "kfold"] && selection.removals.isEmpty, "Multiple selected SSH additions form one staged update")
    selection.toggle("nutella1")
    check(selection.removals == ["nutella1"] && selection.original.contains("nutella1"), "Unchecking a server stages removal without changing saved connections")
    selection.rebase(connected: ["nutella2", "h100-vla"])
    check(selection.additions == ["kfold"] && selection.removals.isEmpty, "Retry after partial success only touches unfinished SSH changes")
    selection.toggle("kfold")
    check(!selection.hasChanges, "Reverting a selection cancels all pending connection changes")
    let reopened = RemoteConnectionSelection(connected: ["nutella1", "nutella2"])
    check(reopened.selected == ["nutella1", "nutella2"] && !reopened.hasChanges, "Cancel and reopen restore actual connected hosts")
    check(SSHConfigHosts.tokens("  Host = \"nutella1\" nutella2 # comment") == ["Host", "nutella1", "nutella2"], "SSH aliases support equals, quotes, comments and multiple names")
    check(SSHConfigHosts.tokens("Include \"config dir/*.conf\"") == ["Include", "config dir/*.conf"], "SSH Include preserves quoted spaces")
    do {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("notchwave-ssh-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent(".ssh")
        let includes = ssh.appendingPathComponent("config dir")
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        try """
        # Host ignored-comment
        Host nutella1 nutella2
          HostName not-an-alias.example
          IdentityFile /do/not/read/key
        Host * !skip *.example host?
        Include "config dir/*.conf"
        Match exec "touch /do/not/execute"
        Host explicit-name
        """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host h100-vla nutella1\nInclude config\n".write(to: includes.appendingPathComponent("one.conf"), atomically: true, encoding: .utf8)
        try "host=kfold\n".write(to: includes.appendingPathComponent("two.conf"), atomically: true, encoding: .utf8)
        let result = SSHConfigHosts.read(home: home)
        check(Set(result.hosts) == Set(["nutella1", "nutella2", "h100-vla", "kfold", "explicit-name"]), "SSH discovery reads Include globs without listing wildcard patterns, HostName values or duplicate aliases")
        check(result.unreadableFiles == 0, "Cyclic SSH Includes terminate cleanly")
        try "Host added-later\n".write(to: includes.appendingPathComponent("three.conf"), atomically: true, encoding: .utf8)
        check(SSHConfigHosts.read(home: home).hosts.contains("added-later"), "SSH list refresh picks up new configured hosts")
        check(SSHConfigHosts.read(home: home.appendingPathComponent("missing-home")).hosts.isEmpty, "Missing SSH configuration has an empty list")
    } catch { fatalError("SSH config discovery checks failed: \(error)") }
}
