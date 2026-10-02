import Foundation

@MainActor func runClaudeUsageChecks(_ check: (Bool, String) -> Void) {
    let now = Date(timeIntervalSince1970: 20_000)
    do {
        let payload: [String: Any] = ["schema": 1, "state": "ok", "source": "api", "sampled_at": 19_900,
            "account": ["email": "person@example.com", "plan": "max", "identity": "account-one"],
            "windows": [["id": "five_hour", "used": 28.0, "resets_at": 22_000],
                        ["id": "seven_day", "used": 8.0], ["id": "seven_day_fable", "used": 0.0],
                        ["id": "context_window", "used": 99.0], ["id": "seven_day_bool", "used": true]]]
        let account = try ClaudeUsageAccount.decode(JSONSerialization.data(withJSONObject: payload), now: now)
        check(account.snapshot?.windows.count == 3, "Claude account view accepts quotas only, excluding context usage and booleans")
        check(account.snapshot?.windows.last?.used == 0, "A real zero-percent Fable limit remains visible")
        check(account.snapshot?.windows.map(\.label) == ["세션 · 5시간", "주간 · 7일", "주간 · Fable"], "Claude names session, weekly and model-specific windows")
        check(account.accountLabel == "person@example.com · Max", "Each Claude server shows its own account and plan")
        check(account.snapshot?.windows.first?.remaining == 72, "Claude used percentages do not become remaining percentages")
        var expired = payload; expired["state"] = "expired"; expired["windows"] = []
        let expiredAccount = try ClaudeUsageAccount.decode(JSONSerialization.data(withJSONObject: expired), now: now)
        check(expiredAccount.snapshot == nil && expiredAccount.message.contains("만료"), "Expired remote credentials display an actionable state instead of invented quota")
        var invalid = payload; invalid["sampled_at"] = 20_100
        check(try ClaudeUsageAccount.decode(JSONSerialization.data(withJSONObject: invalid), now: now).snapshot == nil, "Future quota timestamps are rejected")
        invalid["schema"] = 99
        check((try? ClaudeUsageAccount.decode(JSONSerialization.data(withJSONObject: invalid), now: now)) == nil, "Unknown quota transport schemas are rejected")
        let demo = UsageBridge(demo: true)
        check(demo.claudeLocations == [ClaudeUsageAccount.localID, "studio", "research"], "Claude local and remote locations remain distinct")
        check(demo.claudeAccounts["studio"]?.email != demo.claudeAccounts["research"]?.email, "Switching SSH tabs selects a separate account record")
    } catch { fatalError("Claude quota checks failed: \(error)") }
}
