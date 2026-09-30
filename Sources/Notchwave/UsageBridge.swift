import AppKit
import Foundation
import SwiftUI

struct UsageWindow: Identifiable, Equatable {
    let id: String
    let label: String
    let used: Double
    let resetsAt: Date?
    var remaining: Double { max(0, min(100, 100 - used)) }
}

struct UsageSnapshot: Equatable {
    let windows: [UsageWindow]
    let sampledAt: Date
    var stale: Bool { Date().timeIntervalSince(sampledAt) > 600 || windows.contains { ($0.resetsAt ?? .distantFuture) < Date() } }
    static func codex(_ result: [String: Any], now: Date = Date()) -> UsageSnapshot {
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        let legacy = result["rateLimits"] as? [String: Any]
        let values = buckets?.isEmpty == false ? buckets! : legacy.map { ["codex": $0] } ?? [:]
        var windows: [UsageWindow] = []
        for (id, bucket) in values.sorted(by: { $0.key < $1.key }) {
            for key in ["primary", "secondary"] {
                guard let w = bucket[key] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite else { continue }
                let mins = (w["windowDurationMins"] as? NSNumber)?.intValue
                let label: String
                if let mins, mins >= 1440 && mins % 1440 == 0 { label = "\(mins / 1440)일 한도" }
                else if let mins, mins >= 60 && mins % 60 == 0 { label = "\(mins / 60)시간 한도" }
                else if let mins { label = "\(mins)분 한도" }
                else { label = key == "primary" ? "기본 한도" : "추가 한도" }
                let prefix = values.count > 1 ? ((bucket["limitName"] as? String) ?? id) + " · " : ""
                windows.append(UsageWindow(id: id + key, label: prefix + label, used: used,
                                           resetsAt: ((w["resetsAt"] as? NSNumber)?.doubleValue).map(Date.init(timeIntervalSince1970:))))
            }
        }
        return UsageSnapshot(windows: windows, sampledAt: now)
    }
    static func claude(_ payload: [String: Any], sampledAt: Date) -> UsageSnapshot {
        let limits = payload["rate_limits"] as? [String: [String: Any]] ?? [:]
        let windows = [("five_hour", "5시간 한도"), ("seven_day", "7일 한도"), ("spend_limit", "계정 지출 한도")].compactMap { key, label -> UsageWindow? in
            guard let w = limits[key], let used = (w["used_percentage"] as? NSNumber)?.doubleValue, used.isFinite else { return nil }
            return UsageWindow(id: key, label: label, used: used, resetsAt: ((w["resets_at"] as? NSNumber)?.doubleValue).map(Date.init(timeIntervalSince1970:)))
        }
        return UsageSnapshot(windows: windows, sampledAt: sampledAt)
    }
}

struct UsageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum LocalTool {
    static func executable(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
    static func codexHome() -> URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent(".config/codex")
        return FileManager.default.fileExists(atPath: desktop.appendingPathComponent("auth.json").path) ? desktop : home.appendingPathComponent(".codex")
    }
    static func timed(_ process: Process, seconds: Double) -> DispatchWorkItem {
        let timeout = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
        return timeout
    }
    static func version(_ name: String) throws -> String {
        guard let binary = executable(name) else { throw UsageError(message: "\(name) 앱 도구를 찾지 못했습니다.") }
        let process = Process(), out = Pipe()
        process.executableURL = binary; process.arguments = ["--version"]; process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let timeout = timed(process, seconds: 5); defer { timeout.cancel() }
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum CodexUsageReader {
    static func read() throws -> UsageSnapshot {
        guard let binary = LocalTool.executable("codex") else { throw UsageError(message: "Codex CLI를 설치하고 ChatGPT 계정으로 로그인해 주세요.") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = binary; process.arguments = ["app-server", "--stdio"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = LocalTool.codexHome().path
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let timeout = LocalTool.timed(process, seconds: 20)
        defer { timeout.cancel(); try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() }; try? output.fileHandleForReading.close() }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value); data.append(10); try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "notchwave", "title": "Notchwave", "version": "0.5.0"]]])
        var buffer = Data()
        while process.isRunning {
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { break }
            buffer.append(data)
            guard buffer.count < 2_000_000 else { throw UsageError(message: "Codex 응답을 읽지 못했습니다.") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = message["id"] as? Int else { continue }
                if message["error"] != nil { throw UsageError(message: "Codex 사용량을 가져오지 못했습니다. ChatGPT 로그인 상태를 확인해 주세요.") }
                if id == 1 {
                    try send(["method": "initialized"]); try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = message["result"] as? [String: Any] {
                    let snapshot = UsageSnapshot.codex(result)
                    guard !snapshot.windows.isEmpty else { throw UsageError(message: "이 계정에서 제공되는 사용 한도가 없습니다. API 키 계정은 구독 잔량을 제공하지 않습니다.") }
                    return snapshot
                }
            }
        }
        throw UsageError(message: "Codex 응답 시간이 초과되었습니다. 연결을 확인하고 다시 시도해 주세요.")
    }
}

// Claude Code owns authentication and publishes documented quota data through statusLine.
// The helper keeps only percentages/reset dates, never credentials, prompts or transcripts.
enum ClaudeUsageLink {
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Notchwave") }
    static var cacheURL: URL { directory.appendingPathComponent("claude-usage.json") }
    static var recordURL: URL { directory.appendingPathComponent("claude-statusline-link.json") }
    static var settingsURL: URL {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return root.appendingPathComponent("settings.json")
    }
    static func supported(_ version: String) -> Bool {
        guard let token = version.split(whereSeparator: { $0.isWhitespace }).first else { return false }
        let numbers = token.split(separator: ".").compactMap { Int($0) }
        guard numbers.count >= 3 else { return false }
        return numbers[0] > 2 || (numbers[0] == 2 && (numbers[1] > 1 || (numbers[1] == 1 && numbers[2] >= 251)))
    }
    static func object(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw UsageError(message: "Claude 설정 형식을 읽지 못했습니다. 기존 설정을 그대로 유지했습니다.") }
        return object
    }
    static func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func install(settings: URL = settingsURL, record: URL = recordURL, executable: String = CommandLine.arguments[0]) throws {
        var config = try object(settings)
        let priorRecord = try object(record)
        let current = config["statusLine"] as? [String: Any]
        if let oldCommand = priorRecord["installedCommand"] as? String, current?["command"] as? String == oldCommand { return }
        if let current, current["type"] as? String != "command" { throw UsageError(message: "현재 Claude 상태 표시줄 형식은 자동 연결을 지원하지 않습니다. 기존 설정은 유지했습니다.") }
        let command = shellQuote(executable) + " --capture-claude-usage"
        let backup: [String: Any] = ["previous": config["statusLine"] ?? NSNull(), "installedCommand": command]
        try write(backup, to: record)
        config["statusLine"] = ["type": "command", "command": command]
        try write(config, to: settings)
    }
    static func uninstall(settings: URL = settingsURL, record: URL = recordURL) throws {
        var config = try object(settings); let backup = try object(record)
        guard let command = backup["installedCommand"] as? String,
              (config["statusLine"] as? [String: Any])?["command"] as? String == command else { return }
        if let previous = backup["previous"], !(previous is NSNull) { config["statusLine"] = previous }
        else { config.removeValue(forKey: "statusLine") }
        try write(config, to: settings)
    }
    static func capture(_ input: Data, cache: URL = cacheURL) throws {
        guard let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
        let snapshot = UsageSnapshot.claude(payload, sampledAt: Date())
        guard !snapshot.windows.isEmpty else { return }
        var sanitized: [String: [String: Any]] = [:]
        for window in snapshot.windows {
            var value: [String: Any] = ["used_percentage": window.used]
            if let reset = window.resetsAt { value["resets_at"] = reset.timeIntervalSince1970 }
            sanitized[window.id] = value
        }
        var record: [String: Any] = ["rate_limits": sanitized, "sampledAt": snapshot.sampledAt.timeIntervalSince1970]
        if cache == cacheURL, let account = accountUUID() { record["accountUUID"] = account }
        try write(record, to: cache)
    }
    static func accountUUID() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let metadata = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") }
            ?? home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: metadata), data.count < 8_000_000,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = raw["oauthAccount"] as? [String: Any], let id = account["accountUuid"] as? String, id.count <= 160 else { return nil }
        return id
    }
    static func read() throws -> UsageSnapshot? {
        let raw = try object(cacheURL)
        guard let sampled = raw["sampledAt"] as? Double else { return nil }
        let snapshot = UsageSnapshot.claude(raw, sampledAt: Date(timeIntervalSince1970: sampled))
        return snapshot.windows.isEmpty ? nil : snapshot
    }
    static func runHelper() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard input.count < 2_000_000 else { return }
        try? capture(input)
        let backup = try? object(recordURL)
        if let previous = backup?["previous"] as? [String: Any], let command = previous["command"] as? String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
            process.standardInput = pipe; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.nullDevice
            do { try process.run(); let timeout = LocalTool.timed(process, seconds: 5); try pipe.fileHandleForWriting.write(contentsOf: input); try pipe.fileHandleForWriting.close(); process.waitUntilExit(); timeout.cancel() } catch { }
        } else if let snapshot = try? read(), let first = snapshot.windows.first { print("Claude · \(Int(first.remaining.rounded()))% 남음") }
    }
}

@MainActor final class UsageBridge: ObservableObject {
    @Published var codexEnabled: Bool
    @Published var claudeEnabled: Bool
    @Published private(set) var codex: UsageSnapshot?
    @Published private(set) var claude: UsageSnapshot?
    @Published private(set) var codexMessage = "Codex 계정을 연결하면 남은 사용량을 표시합니다."
    @Published private(set) var claudeMessage = "Claude Code 계정을 연결하면 남은 사용량을 표시합니다."
    @Published private(set) var codexLoading = false
    @Published private(set) var claudeLoading = false
    @Published private(set) var claudeNeedsUpdate = false
    @Published private(set) var claudeAccounts: [String: ClaudeUsageAccount] = [:]
    @Published private(set) var claudeHosts: [String] = []
    @Published private(set) var loadingClaudeHosts: Set<String> = []
    @Published var selectedClaudeHost = ""
    private var lastClaudeRequests: [String: Date] = [:]
    private var claudeRequests: [String: UUID] = [:]
    private var stopped = false
    var claudeLocations: [String] { (claudeEnabled ? [ClaudeUsageAccount.localID] : []) + claudeHosts }
    let demo: Bool
    private var timer: Timer?
    private var lastCodexRequest = Date.distantPast
    private var codexGeneration = 0
    init(demo: Bool = false) {
        self.demo = demo
        codexEnabled = demo || UserDefaults.standard.bool(forKey: "usageCodexEnabled")
        claudeEnabled = demo || UserDefaults.standard.bool(forKey: "usageClaudeEnabled")
        if demo {
            codex = UsageSnapshot(windows: [.init(id: "5h", label: "5시간 한도", used: 32, resetsAt: Date().addingTimeInterval(8200)), .init(id: "7d", label: "7일 한도", used: 18, resetsAt: Date().addingTimeInterval(280000))], sampledAt: Date())
            claude = UsageSnapshot(windows: [.init(id: "5h", label: "5시간 한도", used: 47, resetsAt: Date().addingTimeInterval(4000)), .init(id: "7d", label: "7일 한도", used: 24, resetsAt: Date().addingTimeInterval(160000))], sampledAt: Date())
            claudeHosts = ["studio", "research"]
            let sample = UsageSnapshot(windows: [.init(id: "five_hour", label: "세션 · 5시간", used: 28, resetsAt: Date().addingTimeInterval(7200)), .init(id: "seven_day", label: "주간 · 7일", used: 8, resetsAt: Date().addingTimeInterval(259200)), .init(id: "seven_day_fable", label: "주간 · Fable", used: 0, resetsAt: Date().addingTimeInterval(259200))], sampledAt: Date())
            for host in [ClaudeUsageAccount.localID, "studio", "research"] {
                claudeAccounts[host] = ClaudeUsageAccount(email: host == "research" ? "research@example.com" : "personal@example.com", plan: "Max", identity: host, state: "ok", snapshot: sample, source: "demo")
            }
            selectedClaudeHost = "studio"
        }
    }
    func start() {
        guard !demo, timer == nil else { return }
        stopped = false
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 5
    }
    func stop() {
        timer?.invalidate(); timer = nil; stopped = true
        claudeRequests.removeAll(); loadingClaudeHosts.removeAll(); lastClaudeRequests.removeAll()
    }
    func chooseCodex(_ enabled: Bool) {
        codexEnabled = enabled; codexGeneration += 1
        guard !demo else { return }
        UserDefaults.standard.set(enabled, forKey: "usageCodexEnabled")
        if enabled { refreshCodex(force: true) } else { codex = nil; codexLoading = false; codexMessage = "연결하지 않음" }
    }
    func chooseClaude(_ enabled: Bool) {
        claudeEnabled = enabled
        guard !demo else { return }
        UserDefaults.standard.set(enabled, forKey: "usageClaudeEnabled")
        if enabled { connectClaude(); selectedClaudeHost = ClaudeUsageAccount.localID; refreshClaudeAccounts(force: true) }
        else {
            do { try ClaudeUsageLink.uninstall() } catch { claudeMessage = error.localizedDescription }
            claude = nil
            refreshClaudeAccounts(force: false)
        }
    }
    func refresh(force: Bool = false) {
        guard !demo else { return }
        if codexEnabled { refreshCodex(force: force) }
        refreshClaudeAccounts(force: force)
        if claudeEnabled {
            do {
                claude = try ClaudeUsageLink.read()
                if claude == nil && !claudeNeedsUpdate { claudeMessage = "Claude Code에서 대화한 뒤 사용량이 갱신됩니다. 연결되지 않았다면 아래 연결 버튼을 눌러 주세요." }
            } catch { claudeMessage = "Claude 사용량을 읽지 못했습니다. 다시 연결해 주세요." }
        }
    }
    func refreshClaudeAccounts(force: Bool = false) {
        guard !demo, !stopped else { return }
        claudeHosts = RemoteClaude.hosts()
        let locations = Set(claudeLocations)
        for key in Set(claudeAccounts.keys).union(claudeRequests.keys) where !locations.contains(key) {
            claudeAccounts.removeValue(forKey: key); claudeRequests.removeValue(forKey: key)
            loadingClaudeHosts.remove(key); lastClaudeRequests.removeValue(forKey: key)
        }
        if !locations.contains(selectedClaudeHost) { selectedClaudeHost = claudeLocations.first ?? "" }
        for host in claudeLocations {
            let local = host == ClaudeUsageAccount.localID
            guard claudeRequests[host] == nil, force || Date().timeIntervalSince(lastClaudeRequests[host] ?? .distantPast) >= (local ? 30 : 180) else { continue }
            let request = UUID(); claudeRequests[host] = request
            loadingClaudeHosts.insert(host); lastClaudeRequests[host] = Date()
            Task {
                let result = await Task.detached { Result { try ClaudeUsageReader.read(host: local ? nil : host, force: force) } }.value
                guard !stopped, claudeRequests[host] == request,
                      local ? claudeEnabled : RemoteClaude.hosts().contains(host) else { return }
                claudeRequests.removeValue(forKey: host); loadingClaudeHosts.remove(host)
                switch result {
                case .success(let value): claudeAccounts[host] = value
                case .failure: claudeAccounts[host] = .unavailable(local ? "cli_unavailable" : "offline")
                }
            }
        }
    }
    private func refreshCodex(force: Bool) {
        guard !codexLoading, force || Date().timeIntervalSince(lastCodexRequest) >= 180 else { return }
        lastCodexRequest = Date(); codexLoading = true; codexGeneration += 1; let generation = codexGeneration
        Task {
            let result = await Task.detached { Result { try CodexUsageReader.read() } }.value
            guard codexEnabled, generation == codexGeneration else { return }
            codexLoading = false
            switch result {
            case .success(let value): codex = value; codexMessage = ""
            case .failure(let error): codexMessage = error.localizedDescription
            }
        }
    }
    func connectClaude() {
        guard !demo, !claudeLoading else { return }
        claudeLoading = true
        Task {
            let version = await Task.detached { try? LocalTool.version("claude") }.value
            guard claudeEnabled else { claudeLoading = false; return }
            defer { claudeLoading = false }
            guard let version else { claudeMessage = "Claude Code를 설치하고 계정에 로그인해 주세요."; return }
            guard ClaudeUsageLink.supported(version) else {
                claudeNeedsUpdate = true
                claudeMessage = "Claude Code 업데이트가 필요합니다. 사용량 공유는 2.1.251 이상에서 지원합니다. 업데이트 후 다시 연결해 주세요."
                return
            }
            do {
                try ClaudeUsageLink.install()
                claudeNeedsUpdate = false
                claudeMessage = "연결했습니다. Claude Code를 다시 열고 대화하면 사용량이 표시됩니다."
                claude = try ClaudeUsageLink.read()
            } catch { claudeMessage = error.localizedDescription }
        }
    }
}
