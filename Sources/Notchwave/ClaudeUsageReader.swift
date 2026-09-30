import Foundation
import CoreFoundation

struct ClaudeUsageAccount: Equatable {
    static let localID = "@local"
    let email: String
    let plan: String
    let identity: String
    let state: String
    let snapshot: UsageSnapshot?
    let source: String
    var accountLabel: String {
        let name = email.isEmpty ? (state == "not_signed_in" ? "로그인되지 않음" : "계정 확인 필요") : email
        return name + (plan.isEmpty ? "" : " · " + plan.capitalized)
    }
    var message: String {
        switch state {
        case "ok": return ""
        case "cached": return "Claude에서 마지막으로 확인한 사용량입니다."
        case "waiting": return "Claude Code에서 대화하거나 /usage를 확인하면 사용량이 표시됩니다."
        case "not_signed_in": return "이 위치의 Claude Code에 로그인한 뒤 새로고침해 주세요."
        case "expired": return "Claude 인증이 만료되었습니다. 해당 서버에서 Claude를 열어 인증을 갱신한 뒤 새로고침해 주세요."
        case "cli_unavailable": return "Claude Code를 찾지 못했습니다. 설치와 실행 경로를 확인해 주세요."
        case "rate_limited": return "조회 요청이 잠시 제한됐습니다. 잠시 후 자동으로 다시 확인합니다."
        case "forbidden": return "이 계정에서 사용량 조회를 허용하지 않았습니다. Claude의 /usage에서 확인해 주세요."
        case "unsupported": return "이 로그인 방식은 구독 사용 한도를 제공하지 않습니다."
        case "account_changed": return "조회 중 계정이 변경되었습니다. 다시 새로고침해 주세요."
        case "offline": return "SSH에 연결하지 못했습니다. 서버 연결을 확인해 주세요."
        default: return "사용량을 가져오지 못했습니다. Claude의 로그인 상태를 확인한 뒤 다시 시도해 주세요."
        }
    }
    static func unavailable(_ state: String) -> Self {
        Self(email: "", plan: "", identity: "", state: state, snapshot: nil, source: "")
    }
    static func decode(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 65536, let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["schema"] as? Int == 1, let state = raw["state"] as? String, state.count < 40 else {
            throw UsageError(message: "Claude 사용량 응답 형식을 확인하지 못했습니다.")
        }
        let account = raw["account"] as? [String: Any] ?? [:]
        func text(_ key: String, maximum: Int) -> String {
            String(String.UnicodeScalarView((account[key] as? String ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(maximum)))
        }
        let rawWindows = raw["windows"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        let windows: [UsageWindow] = rawWindows.prefix(12).compactMap { entry in
            guard let id = entry["id"] as? String, let label = windowLabel(id), seen.insert(id).inserted,
                  let number = entry["used"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= 100_000 else { return nil }
            let used = number.doubleValue
            let reset = (entry["resets_at"] as? Double).flatMap { $0.isFinite && $0 > 0 && $0 < 32_503_680_000 ? Date(timeIntervalSince1970: $0) : nil }
            let name = (entry["name"] as? String).map { String($0.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines) }
            let title = id.hasPrefix("seven_day_") && name?.isEmpty == false
                ? "주간 · " + name! : label
            return UsageWindow(id: id, label: title, used: used, resetsAt: reset)
        }
        let sampled = (raw["sampled_at"] as? Double).flatMap { $0.isFinite && $0 > 0 && $0 <= now.timeIntervalSince1970 + 60 ? Date(timeIntervalSince1970: $0) : nil }
        let snapshot = sampled.flatMap { sample in windows.isEmpty ? nil : UsageSnapshot(windows: windows, sampledAt: sample) }
        return Self(email: text("email", maximum: 160), plan: text("plan", maximum: 40), identity: text("identity", maximum: 64),
                    state: state, snapshot: snapshot, source: String((raw["source"] as? String ?? "").prefix(30)))
    }
    static func windowLabel(_ id: String) -> String? {
        if id == "five_hour" { return "세션 · 5시간" }
        if id == "seven_day" { return "주간 · 7일" }
        if id == "spend_limit" { return "계정 지출 한도" }
        if id == "extra_usage" { return "추가 사용량" }
        guard id.range(of: #"^(five_hour|seven_day)_[a-z0-9_]{1,48}$"#, options: .regularExpression) != nil else { return nil }
        let weekly = id.hasPrefix("seven_day_")
        let suffix = String(id.dropFirst(10)).replacingOccurrences(of: "_", with: " ").capitalized
        return (weekly ? "주간 · " : "5시간 · ") + suffix
    }
}

enum ClaudeUsageReader {
    static func read(host: String?, force: Bool = false) throws -> ClaudeUsageAccount {
        guard let resource = Bundle.main.url(forResource: "claude-usage", withExtension: "py") else {
            throw UsageError(message: "Claude 사용량 연결 파일을 찾지 못했습니다.")
        }
        let data: Data
        if let host {
            // The reader executes on the server. Only quota and account labels cross SSH.
            // Match a normal SSH login: ~/.bash_profile / ~/.zprofile can select a different
            // Claude account directory than a bare noninteractive SSH command.
            let reader = "python3 -" + (force ? " --force" : "")
            let command = RemoteClaude.loginCommand(reader)
            data = try RemoteClaude.run(host: host, command: command, input: Data(contentsOf: resource))
        } else {
            let process = Process(), output = Pipe()
            process.executableURL = LocalTool.executable("python3") ?? URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [resource.path, "--local"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            try process.run(); let timeout = LocalTool.timed(process, seconds: 15); defer { timeout.cancel() }
            var result = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                result.append(chunk)
                if result.count > 65536 { process.terminate(); break }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, result.count <= 65536 else { throw UsageError(message: "Claude 계정을 확인하지 못했습니다.") }
            data = result
        }
        return try ClaudeUsageAccount.decode(data)
    }
}
