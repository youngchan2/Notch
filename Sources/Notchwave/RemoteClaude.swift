import AppKit
import Foundation

enum RemoteClaude {
    static var configURL: URL { AIHookLink.directory.appendingPathComponent("RemoteClaude.json") }
    static var seenURL: URL { AIHookLink.directory.appendingPathComponent("RemoteClaudeSeen.json") }
    static let helper = "\"$HOME/.local/share/notchwave/remote-claude.py\""
    static func validHost(_ value: String) -> Bool {
        value.count <= 100 && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._@-]*$"#, options: .regularExpression) != nil
    }
    static func validKey(_ value: String) -> Bool {
        value.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }
    static func hosts() -> [String] {
        guard let data = try? Data(contentsOf: configURL), data.count <= 16384,
              let hosts = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Array(Set(hosts.filter(validHost))).sorted()
    }
    static func saveHosts(_ hosts: [String]) throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Array(Set(hosts.filter(validHost))).sorted()).write(to: configURL, options: .atomic)
    }
    static func arguments(host: String, command: String) -> [String] {
        ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-o", "ControlMaster=no",
         "-o", "ControlPath=none", "--", host, command]
    }
    static func run(host: String, command: String, input: Data? = nil) throws -> Data {
        guard validHost(host) else { throw UsageError(message: "SSH 서버 이름을 확인해 주세요.") }
        let process = Process(), output = Pipe(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments(host: host, command: command)
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : pipe.fileHandleForReading
        try process.run()
        let timeout = LocalTool.timed(process, seconds: 20)
        defer { timeout.cancel() }
        if let input { try? pipe.fileHandleForWriting.write(contentsOf: input); try? pipe.fileHandleForWriting.close() }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 65536 { process.terminate(); break }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 65536 else {
            throw UsageError(message: "\(host) 연결을 확인해 주세요. SSH 키 로그인·Python 3.8 이상·기존 Claude 설정이 필요합니다.")
        }
        return data
    }
    static func configure(host: String, enabled: Bool) throws {
        let data: Data
        if enabled {
            guard let resource = Bundle.main.url(forResource: "remote-claude", withExtension: "py") else {
                throw UsageError(message: "원격 알림 연결 파일이 없습니다. 앱을 다시 빌드해 주세요.")
            }
            let source = try Data(contentsOf: resource)
            let bootstrap = #"""
            import os,pathlib,sys,tempfile,runpy
            source=sys.stdin.read()
            root=pathlib.Path.home()/'.local/share/notchwave'
            if any(p.is_symlink() for p in (root,*root.parents)): raise ValueError('Symbolic link directory')
            root.mkdir(parents=True,exist_ok=True,mode=0o700)
            os.chmod(root,0o700)
            path=root/'remote-claude.py'
            if path.is_symlink() or (path.exists() and not path.read_text().startswith('# notchwave-remote-claude-v1')): raise ValueError('Unrecognized helper')
            fd,tmp=tempfile.mkstemp(dir=root)
            with os.fdopen(fd,'w') as f:
                os.fchmod(f.fileno(),0o600)
                f.write(source)
            os.replace(tmp,path)
            sys.argv=[str(path),'install']
            runpy.run_path(str(path),run_name='__main__')
            """#
            data = try run(host: host, command: "python3 -c " + ClaudeUsageLink.shellQuote(bootstrap), input: source)
        } else {
            data = try run(host: host, command: "python3 " + helper + " remove")
        }
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["type"] as? String == (enabled ? "installed" : "removed") else {
            throw UsageError(message: "\(host)의 알림 등록 결과를 확인하지 못했습니다.")
        }
        var values = hosts(); values.removeAll { $0 == host }
        if enabled { values.append(host) }
        try saveHosts(values)
    }
    static func event(_ wire: [String: Any], host: String, now: Date = Date()) -> AIEvent? {
        guard validHost(host), let id = wire["id"] as? String, let uuid = UUID(uuidString: id),
              let session = wire["session"] as? String, !session.isEmpty, session.count <= 200,
              let key = wire["key"] as? String, validKey(key), let hook = wire["hook"] as? String,
              let timestamp = wire["created"] as? Double, timestamp.isFinite,
              let project = wire["project"] as? String, project.count <= 64,
              let tool = wire["tool"] as? String, tool.count <= 200 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        guard date > now.addingTimeInterval(-3600), date < now.addingTimeInterval(60) else { return nil }
        var payload: [String: Any] = ["hook_event_name": hook, "session_id": session, "cwd": project, "tool_name": tool]
        if hook == "Notification" { payload["notification_type"] = "permission_prompt" }
        guard var event = AIEvent.decodeHook(payload, provider: .claude,
            environment: ["TERM_PROGRAM": "ghostty"], now: date) else { return nil }
        event.id = uuid; event.remoteHost = host
        event.remoteSessionKey = (wire["can_attach"] as? Bool == true) ? key : nil
        event.conversationTitle = host + (event.project.isEmpty ? "" : " · " + event.project)
        return event
    }
    static func attachCommand(host: String, key: String) -> String? {
        guard validHost(host), validKey(key) else { return nil }
        return "/usr/bin/ssh -t -- " + ClaudeUsageLink.shellQuote(host) + " "
            + ClaudeUsageLink.shellQuote("python3 " + helper + " attach " + key)
    }
    static func appleString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func openGhostty(host: String, key: String) throws {
        guard let command = attachCommand(host: host, key: key) else { throw UsageError(message: "원격 작업 위치를 확인하지 못했습니다.") }
        // Always create a fresh terminal; never inject commands into a running Claude prompt.
        let source = """
        tell application id "com.mitchellh.ghostty"
            activate
            set cfg to new surface configuration
            set command of cfg to \(appleString(command))
            set wait after command of cfg to true
            if (count of windows) > 0 then
                set targetTab to new tab in front window with configuration cfg
                focus (focused terminal of targetTab)
            else
                new window with configuration cfg
            end if
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw UsageError(message: "Ghostty 연결 명령을 만들지 못했습니다.") }
        script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let detail = number == -1743
                ? "시스템 설정의 개인정보 보호 및 보안 → 자동화에서 Notchwave의 Ghostty 제어를 허용해 주세요."
                : "Ghostty 1.3 이상을 실행하고 자동화 설정을 확인해 주세요. (오류 \(number))"
            throw UsageError(message: detail)
        }
    }
}

// This connection belongs to Notchwave, independent of Ghostty and the tmux client.
@MainActor final class RemoteClaudeConnection {
    let host: String
    var receive: ([String: Any]) -> Void
    var status: (String) -> Void
    private var process: Process?
    private var stopped = false
    init(host: String, receive: @escaping ([String: Any]) -> Void, status: @escaping (String) -> Void) {
        self.host = host; self.receive = receive; self.status = status
    }
    func start() {
        guard !stopped, process == nil else { return }
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        child.arguments = RemoteClaude.arguments(host: host, command: "python3 -u " + RemoteClaude.helper + " watch")
        child.standardOutput = output; child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        let frames = RemoteClaudeFrames()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            for line in frames.append(chunk) {
                Task { @MainActor in
                    guard let self, !self.stopped, self.process === child,
                          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          object["notchwave"] as? Int == 1 else { return }
                    if object["type"] as? String == "ready" { self.status("연결됨") }
                    if object["type"] as? String == "event", let event = object["event"] as? [String: Any] { self.receive(event) }
                }
            }
        }
        child.terminationHandler = { [weak self, weak child] _ in
            Task { @MainActor in
                guard let self, let child, self.process === child else { return }
                self.process = nil
                if !self.stopped {
                    self.status("재연결 중")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
                }
            }
        }
        status("연결 중")
        process = child
        do { try child.run() }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            process = nil; status("재연결 중")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
        }
    }
    func stop() {
        stopped = true
        if let process, process.isRunning { _ = LocalTool.timed(process, seconds: 0) }
        process = nil
    }
}

final class RemoteClaudeFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var discarding = false
    func append(_ chunk: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        var lines: [Data] = []
        for byte in chunk {
            if byte == 10 {
                if !discarding, !data.isEmpty { lines.append(data) }
                data.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                data.append(byte)
                if data.count > 8192 { data.removeAll(keepingCapacity: true); discarding = true }
            }
        }
        return lines
    }
}

@MainActor final class RemoteClaudeMonitor {
    private var connections: [String: RemoteClaudeConnection] = [:]
    private var seen: [UUID] = []
    var receive: (AIEvent) -> Void
    var status: (String, String?) -> Void
    init(receive: @escaping (AIEvent) -> Void, status: @escaping (String, String?) -> Void) {
        self.receive = receive; self.status = status
        if let data = try? Data(contentsOf: RemoteClaude.seenURL), data.count < 65536,
           let values = try? JSONDecoder().decode([UUID].self, from: data) { seen = Array(values.suffix(512)) }
    }
    func reload() {
        let hosts = Set(RemoteClaude.hosts())
        for host in Array(connections.keys) where !hosts.contains(host) {
            connections.removeValue(forKey: host)?.stop(); status(host, nil)
        }
        for host in hosts where connections[host] == nil {
            let connection = RemoteClaudeConnection(host: host, receive: { [weak self] wire in
                guard let self, let event = RemoteClaude.event(wire, host: host), !self.seen.contains(event.id) else { return }
                self.seen.append(event.id); self.seen = Array(self.seen.suffix(512))
                if let data = try? JSONEncoder().encode(self.seen) { try? data.write(to: RemoteClaude.seenURL, options: .atomic) }
                self.receive(event)
            }, status: { [weak self] value in self?.status(host, value) })
            connections[host] = connection; connection.start()
        }
    }
    func stop() { for connection in connections.values { connection.stop() }; connections.removeAll() }
}
