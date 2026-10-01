import AppKit
import Foundation

enum AIProvider: String, Codable, CaseIterable {
    case codex, claude
    var title: String { self == .codex ? "Codex" : "Claude Code" }
    var bundleID: String { self == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop" }
}

enum AIEventKind: String, Codable { case completed, permission, resumed, ended }

// Keep only routing and display metadata. Never persist commands, prompts or transcripts.
struct AIEvent: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var provider: AIProvider
    var session: String
    var kind: AIEventKind
    var project: String
    var tool: String
    var createdAt: Date
    var targetBundleID: String
    var toolKey = ""
    var preview = false
    var conversationTitle: String?
    var hostID: String?
    var remoteHost: String?
    var remoteSessionKey: String?
    var sessionKey: String { provider.rawValue + ":" + (remoteHost.map { $0 + ":" } ?? "") + session }
    // Codex notifications always open the desktop app, even when the hook inherited a terminal.
    var openingBundleID: String { provider == .codex ? provider.bundleID : targetBundleID }
    var openingURL: URL? { provider == .codex && !preview ? CodexThreadMetadata.deepLink(session: session, hostID: hostID) : nil }
    var openingAction: String { remoteSessionKey != nil ? "tmux 열기" : (openingURL == nil ? "앱 열기" : "대화 열기") }
    var conversationLabel: String { conversationTitle ?? (project.isEmpty ? provider.title : project) }

    var title: String {
        switch kind {
        case .completed: return "응답이 준비됐어요"
        case .permission: return "승인이 필요해요"
        case .resumed: return "작업을 계속하고 있어요"
        case .ended: return "대화가 종료됐어요"
        }
    }
    var symbol: String { kind == .permission ? "hand.raised.fill" : "checkmark" }
    var detail: String { [conversationLabel, kind == .permission ? tool : ""].filter { !$0.isEmpty }.joined(separator: " · ") }

    static let allowedTargets: Set<String> = ["com.openai.codex", "com.openai.codex.dev", "com.openai.codex.alpha",
        "com.anthropic.claudefordesktop", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]

    static func decodeHook(_ payload: [String: Any], provider: AIProvider, environment: [String: String] = [:], now: Date = Date()) -> AIEvent? {
        guard let hook = payload["hook_event_name"] as? String,
              let session = payload["session_id"] as? String, !session.isEmpty, session.count <= 200 else { return nil }
        let kind: AIEventKind
        switch hook {
        case "Stop": kind = .completed
        case "PermissionRequest": kind = .permission
        case "Notification":
            guard payload["notification_type"] as? String == "permission_prompt" else { return nil }
            kind = .permission
        case "PostToolUse", "PostToolUseFailure", "UserPromptSubmit": kind = .resumed
        case "SessionEnd", "Interrupt", "StopFailure": kind = .ended
        default: return nil
        }
        func label(_ value: String, limit: Int) -> String {
            String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(limit))
        }
        let project = (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let toolName = payload["tool_name"] as? String ?? ""
        let tool: String
        switch toolName {
        case "Bash", "exec_command", "shell": tool = "명령 실행"
        case "Edit", "Write", "apply_patch": tool = "파일 변경"
        case "Read": tool = "파일 읽기"
        default: tool = toolName.isEmpty ? "" : "도구 사용"
        }
        let terminals = ["Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
                         "vscode": "com.microsoft.VSCode", "ghostty": "com.mitchellh.ghostty", "WarpTerminal": "dev.warp.Warp-Stable"]
        // A desktop-hosted hook may inherit TERM_PROGRAM from an ancestor shell.
        let host = environment["__CFBundleIdentifier"]
        let target = host.flatMap { allowedTargets.contains($0) ? $0 : nil }
            ?? terminals[environment["TERM_PROGRAM"] ?? ""] ?? provider.bundleID
        var event = AIEvent(provider: provider, session: session, kind: kind, project: label(project, limit: 64),
                       tool: tool, createdAt: now, targetBundleID: target, toolKey: label(toolName, limit: 200))
        if provider == .codex && kind == .completed, let turn = payload["turn_id"] as? String, let id = UUID(uuidString: turn) {
            event.id = id // Deduplicate the hook and desktop delivery of this same turn.
        }
        return event
    }
}

struct AIAlertArrival {
    private var presented: [UUID] = []
    private var current: UUID?
    private var until = Date.distantPast
    mutating func update(_ event: AIEvent?, obscured: Bool, now: Date) -> Bool {
        guard !obscured, let event else { return false }
        if !presented.contains(event.id) {
            presented.append(event.id)
            if presented.count > 256 { presented.removeFirst(presented.count - 256) }
            current = event.id
            until = now.addingTimeInterval(2.5)
        }
        return current == event.id && now < until
    }
}

struct AIAlertQueue {
    private(set) var items: [AIEvent] = []
    private(set) var banner: AIEvent?
    private var expiresAt = Date.distantPast
    private var waiting: [AIEvent] = []
    private var seen: [UUID] = []
    private var latest: [String: Date] = [:]
    private var idleCodexAlertID: UUID?
    var pendingCount: Int { items.filter { $0.kind == .permission }.count }
    var idleCodexAlert: AIEvent? { items.first { $0.id == idleCodexAlertID } }

    mutating func receive(_ event: AIEvent, now: Date = Date(), keepCodexVisible: Bool = false) {
        guard !seen.contains(event.id), event.createdAt > now.addingTimeInterval(-3600),
              event.createdAt < now.addingTimeInterval(60),
              event.createdAt >= (latest[event.sessionKey] ?? .distantPast) else { return }
        seen.append(event.id); if seen.count > 256 { seen.removeFirst(seen.count - 256) }
        latest[event.sessionKey] = event.createdAt
        if latest.count > 256 { latest = latest.filter { $0.value > now.addingTimeInterval(-3600) } }
        let duplicatePermission = event.kind == .permission && items.contains { $0.sessionKey == event.sessionKey && $0.kind == .permission }
        if duplicatePermission { return } // PermissionRequest + delayed Notification describe one request.
        func superseded(_ old: AIEvent) -> Bool {
            guard old.sessionKey == event.sessionKey else { return false }
            if event.kind == .resumed && !event.toolKey.isEmpty {
                return old.kind == .permission && old.toolKey == event.toolKey
            }
            return old.kind == .permission || event.kind == .completed || event.kind == .resumed || event.kind == .ended
        }
        items.removeAll(where: superseded)
        waiting.removeAll(where: superseded)
        if let current = banner, superseded(current) { banner = nil }
        if event.kind == .permission || event.kind == .completed {
            items.insert(event, at: 0)
            // Keep pending approvals ahead of the bounded response history.
            let pending = items.filter { $0.kind == .permission }
            items = Array(pending.prefix(50)) + Array(items.filter { $0.kind == .completed }.prefix(20))
            if keepCodexVisible && event.provider == .codex { idleCodexAlertID = event.id }
            if event.kind == .permission {
                if let current = banner { waiting.insert(current, at: 0) }
                banner = event; expiresAt = now.addingTimeInterval(5)
            } else { waiting.append(event) }
        }
        tick(now: now)
    }

    mutating func tick(now: Date = Date(), paused: Bool = false) {
        if paused { expiresAt = now.addingTimeInterval(5); return }
        // An unread Codex alert can occupy the otherwise empty capsule until acknowledged.
        items.removeAll { $0.id != idleCodexAlertID && now.timeIntervalSince($0.createdAt) >= 3600 }
        waiting.removeAll { now.timeIntervalSince($0.createdAt) >= 60 }
        if let current = banner, now >= expiresAt || now.timeIntervalSince(current.createdAt) >= 3600 { banner = nil }
        if banner == nil, !waiting.isEmpty {
            banner = waiting.removeFirst(); expiresAt = now.addingTimeInterval(5)
        }
    }
    mutating func dismiss(_ id: UUID) {
        items.removeAll { $0.id == id }; waiting.removeAll { $0.id == id }
        if banner?.id == id { banner = nil }
        if idleCodexAlertID == id { idleCodexAlertID = nil }
    }
    mutating func updateConversation(_ metadata: CodexThreadMetadata, session: String) {
        func updated(_ event: AIEvent) -> AIEvent {
            guard event.provider == .codex, event.session == session else { return event }
            var result = event
            result.conversationTitle = metadata.title ?? event.conversationTitle
            result.hostID = metadata.hostID
            return result
        }
        items = items.map(updated); waiting = waiting.map(updated)
        if let current = banner { banner = updated(current) }
    }
    mutating func acknowledge(_ id: UUID) {
        waiting.removeAll { $0.id == id }
        if banner?.id == id { banner = nil }
        if idleCodexAlertID == id { idleCodexAlertID = nil }
    }
    mutating func clearIdleCodexAlert() { idleCodexAlertID = nil }
    mutating func clearAll() {
        items.removeAll()
        waiting.removeAll()
        banner = nil
        idleCodexAlertID = nil
        expiresAt = .distantPast
        // Keep delivery history so polling cannot replay an already dismissed event.
    }
    mutating func remove(_ provider: AIProvider) {
        items.removeAll { $0.provider == provider }; waiting.removeAll { $0.provider == provider }
        if banner?.provider == provider { banner = nil }
    }
}

enum AIHookLink {
    static var directory: URL { ClaudeUsageLink.directory.appendingPathComponent("AI Alerts", isDirectory: true) }
    static var inbox: URL { directory.appendingPathComponent("Inbox", isDirectory: true) }
    static func settings(_ provider: AIProvider) -> URL {
        provider == .codex ? LocalTool.codexHome().appendingPathComponent("hooks.json") : ClaudeUsageLink.settingsURL
    }
    static func command(_ provider: AIProvider, executable: String) -> String {
        ClaudeUsageLink.shellQuote(executable) + " --notchwave-ai-event " + provider.rawValue
    }
    static func owned(_ handler: [String: Any], provider: AIProvider) -> Bool {
        guard handler["type"] as? String == "command", let value = handler["command"] as? String else { return false }
        return value.hasSuffix(" --notchwave-ai-event " + provider.rawValue) && value.contains("/Contents/MacOS/Notchwave'")
    }
    static func configured(_ provider: AIProvider, at url: URL? = nil) -> Bool {
        guard let object = try? ClaudeUsageLink.object(url ?? settings(provider)), let hooks = object["hooks"] as? [String: Any] else { return false }
        return ["Stop", "PermissionRequest"].allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { owned($0, provider: provider) }
            }
        }
    }

    static func updated(_ original: [String: Any], provider: AIProvider, executable: String, enabled: Bool) throws -> [String: Any] {
        var config = original
        guard config["hooks"] == nil || config["hooks"] is [String: Any] else {
            throw UsageError(message: "기존 알림 설정 형식을 확인해 주세요. 설정을 변경하지 않았습니다.")
        }
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        let events = provider == .codex
            ? ["Stop", "PermissionRequest", "PostToolUse", "UserPromptSubmit", "SessionEnd", "Interrupt"]
            : ["Stop", "PermissionRequest", "Notification", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "SessionEnd", "StopFailure"]
        for event in events {
            guard hooks[event] == nil || hooks[event] is [[String: Any]] else {
                throw UsageError(message: "기존 \(event) 설정을 읽지 못해 연결을 중단했습니다.")
            }
            var groups: [[String: Any]] = []
            for var group in hooks[event] as? [[String: Any]] ?? [] {
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw UsageError(message: "기존 훅 설정을 읽지 못해 연결을 중단했습니다.")
                }
                let kept = handlers.filter { !owned($0, provider: provider) }
                // Preserve untouched groups byte-for-byte at the object level, including empty groups.
                if kept.count == handlers.count { groups.append(group) }
                else if !kept.isEmpty { group["hooks"] = kept; groups.append(group) }
            }
            if enabled {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command(provider, executable: executable), "timeout": 3]]]
                if event == "Notification" { group["matcher"] = "permission_prompt" }
                groups.append(group)
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { config.removeValue(forKey: "hooks") } else { config["hooks"] = hooks }
        return config
    }

    static func setEnabled(_ enabled: Bool, provider: AIProvider, at url: URL? = nil, executable: String = CommandLine.arguments[0]) throws {
        let url = url ?? settings(provider)
        // Refuse to replace symlinks and recheck before the atomic write to avoid stale updates.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw UsageError(message: "설정 파일이 링크로 관리되고 있습니다. 원본 설정에 직접 연결해 주세요.")
        }
        let before = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
        let original: [String: Any]
        if let before {
            guard let object = try JSONSerialization.jsonObject(with: before) as? [String: Any] else { throw UsageError(message: "설정 파일을 읽지 못했습니다.") }
            original = object
        } else { original = [:] }
        let result = try updated(original, provider: provider, executable: executable, enabled: enabled)
        let current = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
        guard current == before else { throw UsageError(message: "설정이 변경됐습니다. 다시 연결해 주세요.") }
        try ClaudeUsageLink.write(result, to: url)
    }

    static func capture(_ payload: [String: Any], provider: AIProvider, at inbox: URL = inbox,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let event = AIEvent.decodeHook(payload, provider: provider, environment: environment) else { return }
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = inbox.appendingPathComponent(event.id.uuidString + ".json")
        try JSONEncoder().encode(event).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // Keep the inbox bounded even while Notchwave is closed.
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in files.dropFirst(200) { try? FileManager.default.removeItem(at: old) }
    }

    static func runHelper(provider: AIProvider) {
        // A notification must never decide permissions or block the agent on a local error.
        defer { if provider == .codex { print("{}") } }
        var data = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk); if data.count > 2_000_000 { return }
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        try? capture(object, provider: provider)
    }
}

@MainActor final class AIAlertBridge: ObservableObject {
    @Published private(set) var queue = AIAlertQueue()
    @Published private(set) var configured: Set<AIProvider> = []
    @Published private(set) var received: Set<AIProvider> = []
    @Published var message = ""
    @Published private(set) var remoteStatus: [String: String] = [:]
    @Published private(set) var remoteBusy = false
    @Published private(set) var sshHosts: [String] = []
    @Published private(set) var sshReadWarning = ""
    @Published var claudeConnection: ClaudeConnectionStep?
    @Published var claudeManualEntry = false
    let demo: Bool
    var bannerPaused = false
    @Published private(set) var musicPlaying = false
    @Published private(set) var isEmphasized = false
    private var arrival = AIAlertArrival()
    private var timer: Timer?
    private var configurationTicks = 0
    private let desktopCompletions = CodexCompletionMonitor()
    private let threadMetadata = CodexThreadMetadataReader()
    private let desktopReadState = CodexReadStateMonitor()
    private var nextTitleRefresh = Date.distantPast
    private lazy var remote = RemoteClaudeMonitor(receive: { [weak self] event in
        guard let self else { return }
        self.queue.receive(event, keepCodexVisible: !self.musicPlaying)
        self.received.insert(.claude); self.refreshPresentation()
    }, status: { [weak self] host, status in self?.remoteStatus[host] = status })
    init(demo: Bool = false) { self.demo = demo }
    var banner: AIEvent? { queue.banner ?? (musicPlaying ? nil : queue.idleCodexAlert) }
    var pendingCount: Int { queue.pendingCount }
    var items: [AIEvent] { queue.items }

    func start() {
        guard !demo else { return }
        refreshConfiguration(); remote.reload(); poll()
        timer?.invalidate()
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = 0.1
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func stop() { timer?.invalidate(); timer = nil; remote.stop() }
    func refreshPresentation(now: Date = Date()) {
        let emphasized = arrival.update(banner, obscured: bannerPaused, now: now)
        if isEmphasized != emphasized { isEmphasized = emphasized }
    }
    func updatePlayback(playing: Bool) {
        guard musicPlaying != playing else { return }
        musicPlaying = playing
        // Once music takes over, old alerts should not reappear at the next pause.
        if playing { queue.clearIdleCodexAlert() }
        refreshPresentation()
    }
    func refreshConfiguration() {
        let previous = configured
        configured = Set(AIProvider.allCases.filter { AIHookLink.configured($0) })
        if previous.contains(.codex) != configured.contains(.codex) {
            desktopCompletions.reset(); desktopReadState.reset()
        }
    }
    func connect(_ provider: AIProvider) {
        guard !demo else { return }
        do {
            let enabled = !configured.contains(provider)
            try AIHookLink.setEnabled(enabled, provider: provider)
            refreshConfiguration()
            if !enabled { for event in queue.items where event.provider == provider && event.remoteHost == nil { queue.dismiss(event.id) } }
            message = enabled ? (provider == .codex ? "Codex 알림을 등록했습니다. Codex에서 훅을 검토·신뢰한 뒤 새 대화부터 사용할 수 있어요." : "Claude Code 알림을 등록했습니다. 새 세션에서 사용할 수 있어요.") : "\(provider.title) 알림 연결을 해제했습니다."
        } catch { message = error.localizedDescription }
    }
    func showClaudeConnection() {
        guard !demo else { return }
        if !remoteBusy { message = "" }
        claudeConnection = .location
    }
    func closeClaudeConnection() { claudeManualEntry = false; claudeConnection = nil }
    func refreshSSHHosts() {
        let result = SSHConfigHosts.read()
        sshHosts = result.hosts
        sshReadWarning = result.unreadableFiles > 0 ? "일부 SSH 설정 파일을 읽지 못했습니다. 연결된 서버는 계속 표시합니다." : ""
    }
    func applyRemoteChanges(additions: Set<String>, removals: Set<String>) {
        guard !demo, !remoteBusy else { return }
        guard additions.isDisjoint(with: removals), additions.union(removals).allSatisfy(RemoteClaude.validHost) else {
            message = "SSH 서버 이름을 확인해 주세요."; return
        }
        let changes = additions.sorted().map { ($0, true) } + removals.sorted().map { ($0, false) }
        guard !changes.isEmpty else { return }
        remoteBusy = true
        Task {
            var failures: [String] = []
            for (host, enabled) in changes {
                message = "\(host) \(enabled ? "연결" : "연결 해제") 중…"
                do {
                    try await Task.detached { try RemoteClaude.configure(host: host, enabled: enabled) }.value
                    if enabled { remote.reconnect(host: host) } else { remote.reload() }
                    if !enabled { for event in queue.items where event.remoteHost == host { queue.dismiss(event.id) } }
                } catch { failures.append(host) }
            }
            if failures.isEmpty {
                message = "Claude 원격 연결을 적용했습니다."
                closeClaudeConnection()
            } else {
                message = failures.joined(separator: ", ") + " 연결을 변경하지 못했습니다. SSH 연결을 확인하고 다시 시도해 주세요."
            }
            remoteBusy = false; refreshPresentation()
        }
    }
    func poll(now: Date = Date()) {
        guard !demo else { queue.tick(now: now); refreshPresentation(now: now); return }
        configurationTicks += 1
        if configurationTicks >= 20 { refreshConfiguration(); remote.reload(); configurationTicks = 0 }
        let files = (try? FileManager.default.contentsOfDirectory(at: AIHookLink.inbox,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])) ?? []
        var events: [AIEvent] = []
        for file in files.prefix(250) where file.pathExtension == "json" {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            if (values?.fileSize ?? 0) <= 8192, let data = try? Data(contentsOf: file),
               let event = try? JSONDecoder().decode(AIEvent.self, from: data),
               AIEvent.allowedTargets.contains(event.targetBundleID), event.session.count <= 200,
               event.project.count <= 64, event.tool.count <= 64, event.toolKey.count <= 200,
               now.timeIntervalSince(event.createdAt) < 60 {
                events.append(event)
            }
            try? FileManager.default.removeItem(at: file)
        }
        if configured.contains(.codex) { events += desktopCompletions.poll(now: now) }
        for raw in events.sorted(by: { $0.createdAt < $1.createdAt }) where configured.contains(raw.provider) || raw.preview {
            var event = raw
            event.conversationTitle = CodexThreadMetadata.cleanTitle(event.conversationTitle)
            event.hostID = CodexThreadMetadata.validHost(event.hostID)
            if event.provider == .codex, !event.preview, event.kind == .completed || event.kind == .permission,
               let metadata = threadMetadata.lookup(session: event.session) {
                event.conversationTitle = metadata.title; event.hostID = metadata.hostID
                queue.updateConversation(metadata, session: event.session)
            }
            if !event.preview { received.insert(event.provider) }
            queue.receive(event, now: now, keepCodexVisible: !musicPlaying)
        }
        // Auto-generated names may arrive just after the completion notification.
        if now >= nextTitleRefresh {
            nextTitleRefresh = now.addingTimeInterval(3)
            let unnamed = Set(queue.items.filter { $0.provider == .codex && !$0.preview && $0.conversationTitle == nil && now.timeIntervalSince($0.createdAt) < 30 }.map(\.session))
            for session in unnamed {
                if let metadata = threadMetadata.lookup(session: session) { queue.updateConversation(metadata, session: session) }
            }
        }
        if configured.contains(.codex) {
            for id in desktopReadState.readEventIDs(in: queue.items, now: now) { queue.dismiss(id) }
        }
        queue.tick(now: now, paused: bannerPaused)
        refreshPresentation(now: now)
    }
    func preview(permission: Bool = false, conversationTitle: String? = nil) {
        let event = AIEvent(provider: permission ? .claude : .codex, session: "notchwave-preview-\(permission)",
            kind: permission ? .permission : .completed, project: "미리보기", tool: permission ? "파일 변경" : "",
            createdAt: Date(), targetBundleID: permission ? AIProvider.claude.bundleID : AIProvider.codex.bundleID, preview: true,
            conversationTitle: conversationTitle)
        queue.receive(event, keepCodexVisible: !musicPlaying)
        refreshPresentation()
    }
    func dismiss(_ event: AIEvent) { queue.dismiss(event.id); refreshPresentation() }
    func clearAll() { queue.clearAll(); refreshPresentation() }
    func open(_ event: AIEvent) {
        guard !demo else { dismiss(event); return }
        if let host = event.remoteHost, let key = event.remoteSessionKey {
            guard RemoteClaude.validHost(host), RemoteClaude.validKey(key) else { message = "원격 작업 위치를 확인하지 못했습니다."; return }
            Task {
                do {
                    _ = try await Task.detached { try RemoteClaude.run(host: host,
                        command: RemoteClaude.loginCommand("python3 " + RemoteClaude.helper + " check-attach " + key)) }.value
                    try RemoteClaude.openGhostty(host: host, key: key)
                    queue.acknowledge(event.id)
                    if event.kind == .completed { queue.dismiss(event.id) }
                    refreshPresentation()
                } catch { message = error.localizedDescription }
            }
            return
        }
        var target = event
        if event.provider == .codex, let metadata = threadMetadata.lookup(session: event.session) {
            target.conversationTitle = metadata.title ?? event.conversationTitle
            target.hostID = metadata.hostID // Refresh after a thread has moved to another host.
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: event.openingBundleID)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: event.provider.bundleID) else {
            message = "\(event.provider.title) 앱을 찾지 못했습니다. 사용 중인 터미널이나 앱에서 확인해 주세요."; return
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        let completed: (Error?) -> Void = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil { self.message = "대화를 열지 못했습니다. 해당 앱에서 확인해 주세요." }
                else {
                    self.queue.acknowledge(event.id)
                    if event.kind == .completed { self.queue.dismiss(event.id) }
                    self.refreshPresentation()
                }
            }
        }
        if let deepLink = target.openingURL {
            NSWorkspace.shared.open([deepLink], withApplicationAt: url, configuration: configuration) { _, error in completed(error) }
        } else {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in completed(error) }
        }
    }
}
