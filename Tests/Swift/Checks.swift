import AppKit
import SQLite3

@MainActor func runChecks() {
    var count = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAILED: \(message)") }
        count += 1
    }
    runSpotifyChecks { check($0, $1) }
    let date = Date(timeIntervalSince1970: 1000)
    let list = NSAppleEventDescriptor.list()
    let values: [NSAppleEventDescriptor] = [
        .init(string: "spotify:track:test"), .init(string: "따옴표 \"와\" 줄\n바꿈"),
        .init(string: "Artist, 한글"), .init(string: "Album"), .init(string: "https://example.com/cover.jpg"),
        .init(double: 240_000), .init(double: 83.5), .init(string: "playing")
    ]
    for (i, value) in values.enumerated() { list.insert(value, at: i + 1) }
    let track = Track.decode(list, at: date)!
    check(track.title == "따옴표 \"와\" 줄\n바꿈", "Unicode and delimiters survive typed Apple Events")
    check(track.duration == 240, "Spotify milliseconds converted to seconds")
    check(track.elapsed(at: date.addingTimeInterval(2)) == 85.5, "Playing time advances")
    check(track.elapsed(at: date.addingTimeInterval(999)) == 240, "Progress does not exceed duration")
    var paused = track
    paused.playing = false
    check(paused.elapsed(at: date.addingTimeInterval(90)) == 83.5, "Paused time does not advance")
    check(track.progress(at: date.addingTimeInterval(999)) == 1, "Compact progress stops at the end of the track")
    var noDuration = track
    noDuration.duration = 0
    check(noDuration.progress(at: date) == 0, "Unknown duration does not produce an invalid progress width")
    let modes = NSAppleEventDescriptor.list()
    for (i, value) in values.enumerated() { modes.insert(value, at: i + 1) }
    for (i, value) in [true, false, true, false].enumerated() { modes.insert(.init(boolean: value), at: i + 9) }
    let modeTrack = Track.decode(modes, at: date)!
    check(modeTrack.shuffling && !modeTrack.repeating, "Spotify shuffle and repeat states are decoded independently")
    check(modeTrack.canShuffle && !modeTrack.canRepeat, "Unavailable playback modes retain their disabled state")
    let demoPlayer = SpotifyBridge()
    demoPlayer.setDemo(true)
    demoPlayer.send(.shuffle)
    demoPlayer.send(.repeatMode)
    check(demoPlayer.track?.shuffling == true && demoPlayer.track?.repeating == true, "Playback mode controls toggle independently")
    demoPlayer.send(.shuffle)
    check(demoPlayer.track?.shuffling == false && demoPlayer.track?.repeating == true, "Turning shuffle off preserves repeat")
    demoPlayer.track?.canRepeat = false
    demoPlayer.send(.repeatMode)
    check(demoPlayer.track?.repeating == true, "Unsupported repeat control does not change playback state")
    demoPlayer.send(.seek(99_999))
    check(demoPlayer.track?.position == demoPlayer.track?.duration, "Scrubbing clamps to the end of the song")
    demoPlayer.send(.seek(-5))
    check(demoPlayer.track?.position == 0, "Scrubbing before the start clamps to zero")
    demoPlayer.send(.seek(.nan))
    check(demoPlayer.track?.position == 0, "Invalid seek coordinates are ignored")
    check(Track.decode(.list()) == nil, "Empty playback is handled")
    let bad = NSAppleEventDescriptor.list()
    for (i, value) in values.enumerated() { bad.insert(value, at: i + 1) }
    bad.insert(.init(double: -10), at: 6)
    check(Track.decode(bad) == nil, "Malformed data is rejected")
    check(timeLabel(83.5) == "1:23", "Elapsed label")
    check(timeLabel(-5) == "0:00", "Negative elapsed clamped")
    check(timeLabel(.infinity) == "0:00", "Invalid time handled")
    let geometry = IslandGeometry(centerX: -800, topY: 900, notchWidth: 180, topHeight: 37)
    check(geometry.windowFrame.maxY == 900, "Panel anchors to screen top")
    check(geometry.windowFrame.midX == -800, "Secondary screen origin respected")
    check(geometry.hitRect(expanded: false, active: true).contains(NSPoint(x: -800, y: 880)), "Compact hover target")
    check(!geometry.hitRect(expanded: false, active: true).contains(NSPoint(x: -800, y: 700)), "Transparent area is click-through")
    check(geometry.hitRect(expanded: true, active: true).contains(NSPoint(x: -800, y: 710)), "Controls stay within hover target")
    check(geometry.hitRect(expanded: false, active: false).width == 180, "Idle target follows physical notch")
    check(geometry.hitRect(expanded: true, active: true, tab: .calendar).width == 760, "Calendar panel has room for seven days")
    check(geometry.hitRect(expanded: true, active: true, tab: .calendar).contains(NSPoint(x: -460, y: 420)), "Calendar events remain interactive below player bounds")
    check(!geometry.hitRect(expanded: true, active: true).contains(NSPoint(x: -460, y: 420)), "Spotify transparent margins remain click-through")
    let belowNotch = NSPoint(x: geometry.centerX, y: geometry.topY - geometry.topHeight - 10)
    check(geometry.activationRect.contains(belowNotch), "Idle notch opens when approached just below camera cutout")
    check(!geometry.hitRect(expanded: false, active: false).contains(belowNotch), "Wider hover zone does not intercept underlying clicks")
    check(geometry.activationRect.contains(NSPoint(x: geometry.centerX + geometry.notchWidth / 2 + 20, y: 880)), "Idle and playing notch share an easy-to-reach activation zone")
    var hover = PanelHover()
    check(hover.update(inside: true, expanded: false, pinned: false, holdOpenUntil: .distantPast, now: date) == .none, "Passing across notch does not open immediately")
    check(hover.update(inside: true, expanded: false, pinned: false, holdOpenUntil: .distantPast, now: date.addingTimeInterval(0.15)) == .open, "Idle hover opens without a track or calendar authorization")
    check(hover.update(inside: false, expanded: true, pinned: false, holdOpenUntil: .distantPast, now: date.addingTimeInterval(0.3)) == .none, "Brief cursor departure does not flicker")
    check(hover.update(inside: false, expanded: true, pinned: false, holdOpenUntil: .distantPast, now: date.addingTimeInterval(0.7)) == .close, "Leaving idle panel closes it after grace period")
    check(hover.update(inside: false, expanded: true, pinned: true, holdOpenUntil: .distantPast, now: date.addingTimeInterval(1)) == .none, "Explicit pin preserves panel on mouse leave")
    let state = IslandState(expanded: true)
    state.pinned = true
    state.holdOpenUntil = date.addingTimeInterval(6)
    state.dismiss()
    check(!state.expanded && !state.pinned && state.holdOpenUntil == .distantPast, "Outside click dismisses immediately, clearing pin and startup hold")
    hover.reset()
    check(hover.update(inside: true, expanded: false, pinned: false, holdOpenUntil: .distantPast, now: date.addingTimeInterval(2)) == .none, "Dismissal requires a fresh hover dwell")
    check(hover.update(inside: true, expanded: false, pinned: false, holdOpenUntil: .distantPast, now: date.addingTimeInterval(2.15)) == .open, "Panel can reopen after dismissal without restarting playback")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.firstWeekday = 2
    func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    let week = WeekLayout.start(containing: day(2026, 1, 1), calendar: calendar)
    check(week == day(2025, 12, 29), "Week navigation crosses year boundaries")
    let springWeek = WeekLayout.days(from: day(2026, 3, 2), calendar: calendar)
    check(springWeek.count == 7 && springWeek.last == day(2026, 3, 8), "Week dates preserve local midnights across DST")
    func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEntry {
        CalendarEntry(id: id, title: id, start: start, end: end, allDay: allDay, calendarName: "Test", color: .systemBlue, location: "")
    }
    let midnight = event("overnight", day(2026, 9, 21, 23), day(2026, 9, 22, 1))
    let first = WeekLayout.segments([midnight], day: day(2026, 9, 21), calendar: calendar)
    let second = WeekLayout.segments([midnight], day: day(2026, 9, 22), calendar: calendar)
    check(first.first?.startMinute == 1380 && first.first?.endMinute == 1440, "Overnight events clip to first day")
    check(second.first?.startMinute == 0 && second.first?.endMinute == 60, "Overnight events continue on second day")
    let allDay = event("allday", day(2026, 9, 21), day(2026, 9, 23), allDay: true)
    check(WeekLayout.overlaps(allDay, day: day(2026, 9, 22), calendar: calendar), "Multi-day all-day event includes intermediate days")
    check(!WeekLayout.overlaps(allDay, day: day(2026, 9, 23), calendar: calendar), "All-day end date is exclusive")
    check(WeekLayout.segments([allDay], day: day(2026, 9, 21), calendar: calendar).isEmpty, "All-day events stay out of timed grid")
    let overlaps = [event("A", day(2026, 9, 21, 9), day(2026, 9, 21, 11)),
                    event("B", day(2026, 9, 21, 10), day(2026, 9, 21, 12)),
                    event("C", day(2026, 9, 21, 11), day(2026, 9, 21, 13)),
                    event("D", day(2026, 9, 21, 14), day(2026, 9, 21, 15))]
    let lanes = WeekLayout.segments(overlaps, day: day(2026, 9, 21), calendar: calendar)
    check(lanes.map { $0.laneCount } == [2, 2, 2, 1], "Transitive overlaps share columns; separate events regain full width")
    check(lanes.map { $0.lane } == [0, 1, 0, 0], "Non-overlapping events reuse lanes")
    let dst = event("dst", day(2026, 3, 8, 1, 30), day(2026, 3, 8, 3, 30))
    let dstSegment = WeekLayout.segments([dst], day: day(2026, 3, 8), calendar: calendar).first!
    check(dstSegment.startMinute == 90 && dstSegment.endMinute == 210, "Spring DST events use wall-clock positions")
    let evening = event("evening", day(2026, 9, 21, 20), day(2026, 9, 21, 21))
    let afternoon = event("afternoon", day(2026, 9, 21, 14), day(2026, 9, 21, 15))
    let summary = WeekLayout.entries([evening, afternoon, allDay], day: day(2026, 9, 21), calendar: calendar)
    check(summary.map { $0.id } == ["allday", "afternoon", "evening"], "Week summary keeps afternoon and evening events, with all-day first")
    check(WeekLayout.entries([midnight], day: day(2026, 9, 22), calendar: calendar).first?.id == "overnight", "Summary includes events continued from previous day")
    check(WeekLayout.entries([allDay], day: day(2026, 9, 23), calendar: calendar).isEmpty, "Summary honors exclusive all-day end date")
    check(WeekLayout.nextEventID([allDay, evening, afternoon], after: day(2026, 9, 21, 13)) == "afternoon", "Next event skips all-day cards and uses start time")
    check(WeekLayout.nextEventID([afternoon, evening], after: day(2026, 9, 21, 14, 30)) == "evening", "Next highlight advances beyond an already-started event")
    check(WeekLayout.nextEventID([allDay, afternoon, evening], after: day(2026, 9, 22)) == nil, "Past weeks have no next-event highlight")
    let choices = [CalendarChoice(id: "write", title: "Writable", source: "Test", color: .systemBlue, writable: true),
                   CalendarChoice(id: "read", title: "Subscription", source: "Test", color: .systemGray, writable: false)]
    var form = EventForm(day: day(2026, 3, 8), calendarID: "write", calendar: calendar)
    check(form.validation(calendar: calendar, choices: choices) != nil, "New event rejects an empty title")
    form.title = "   \n"
    check(form.validation(calendar: calendar, choices: choices) != nil, "Whitespace-only titles cannot be saved")
    form.title = "Meeting"
    check(form.validation(calendar: calendar, choices: choices) == nil, "Valid new event can be saved")
    form.calendarID = "read"
    check(form.validation(calendar: calendar, choices: choices) != nil, "Read-only calendars cannot receive writes")
    form.calendarID = "removed"
    check(form.validation(calendar: calendar, choices: choices) != nil, "Removed calendars cannot receive writes")
    form.calendarID = "write"
    form.end = form.start
    check(form.dates(calendar: calendar) == nil, "Timed event end must be after start")
    form.allDay = true
    check(form.dates(calendar: calendar)?.duration == 23 * 3600, "Single all-day event uses calendar days across spring DST")
    check(form.dates(calendar: calendar)?.end == day(2026, 3, 9), "All-day inclusive form end converts to exclusive EventKit end")
    form.end = day(2026, 3, 7)
    check(form.dates(calendar: calendar) == nil, "All-day end cannot precede its first day")
    let existingForm = EventForm(event: allDay, calendar: calendar)
    check(existingForm.end == day(2026, 9, 22), "Existing multi-day all-day event displays inclusive last day")
    check(existingForm.dates(calendar: calendar)?.end == allDay.end, "All-day edit round trip preserves stored end")
    var original = event("revision", day(2026, 9, 21, 14), day(2026, 9, 21, 15))
    original.calendarID = "write"
    original.calendarItemID = "item"
    original.lastModified = day(2026, 9, 20)
    check(original.matchesRevision(original), "Unchanged event revision permits update")
    var changed = original
    changed.lastModified = day(2026, 9, 21)
    check(!original.matchesRevision(changed), "Concurrent calendar update is detected")
    changed = original
    changed.notes = "Edited elsewhere"
    check(!original.matchesRevision(changed), "Concurrent field update is detected even if timestamp is unchanged")
    original.editable = false
    check(EventForm(event: original, calendar: calendar).validation(calendar: calendar, choices: choices) != nil, "Read-only event cannot be edited in a writable calendar")
    let glass = IslandGeometry(centerX: 1400, topY: 850, notchWidth: 112, topHeight: 36, hasNotch: false)
    let menuCapsule = IslandGeometry.menuBarCapsule(screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080), menuBarHeight: 24)
    check(menuCapsule.minY >= 1056 && menuCapsule.maxY == 1078, "Collapsed capsule stays inside the menu bar, with a two-point top inset")
    let offsetCapsule = IslandGeometry.menuBarCapsule(screenFrame: NSRect(x: -1920, y: 300, width: 1920, height: 1080), menuBarHeight: 32)
    check(offsetCapsule.midX == -960 && offsetCapsule.maxY == 1378 && offsetCapsule.height == 28, "Menu-bar placement follows display coordinates and menu-bar height")
    check(glass.idleWidth == 112 && glass.compactWidth == 112, "Artwork and waveform fit the compact external-display capsule")
    check(glass.hitRect(expanded: false, active: true).height == glass.topHeight, "External progress bar remains inside the menu bar")
    check(geometry.hitRect(expanded: false, active: true).minY == geometry.topY - geometry.topHeight - 3, "Physical-notch progress line sits below the camera cutout")
    check(glass.hitRect(expanded: false, active: false).maxY == 850, "Floating capsule respects its top inset")
    check(glass.hitRect(expanded: false, active: false).width == 112, "Idle capsule has no fake notch gap")
    check(glass.hitRect(expanded: false, active: false, alert: true).width == 330, "Battery alert click target matches its wider capsule")
    let notchAlert = geometry.hitRect(expanded: false, active: false, alert: true)
    let prominentNotchAlert = geometry.hitRect(expanded: false, active: false, alert: true, aiAlertEmphasized: true)
    check(notchAlert.width <= glass.alertWidth, "Notch notifications fit within the external alert capsule width")
    check(notchAlert == prominentNotchAlert, "Arrival emphasis does not enlarge or misalign the notch notification")
    check(notchAlert == geometry.hitRect(expanded: false, active: false, alert: true, chargingAlert: true), "Charging and AI banners share camera-safe bounds")
    check(notchAlert.contains(NSPoint(x: geometry.centerX, y: geometry.topY - geometry.topHeight - 13)), "Title below the physical camera remains clickable")
    check(geometry.alertWingWidth >= 56 && geometry.notchAlertHeight > geometry.topHeight, "Notification status wings and title have space outside the camera cutout")
    check(glass.hitRect(expanded: true, active: false, tab: .battery).height == 474, "Battery panel has space for six devices")
    check(glass.windowFrame.contains(glass.hitRect(expanded: true, active: false, tab: .usage)), "Usage controls fit inside the host window")
    check(IslandTab.allCases.count == 4 && CalendarBridge.Presentation.allCases.count == 2, "Four top tabs and two calendar modes, with monthly mode removed")
    let rawBattery: [String: Any] = ["Name": "Headphones", "Type": "Accessory Source", "Current Capacity": 20, "Max Capacity": 100, "Accessory Category": "Headphone"]
    let critical = DeviceBattery.parse(rawBattery, computerName: "Mac")!
    check(critical.critical && critical.percent == 20, "20 percent battery is critical")
    var raw = rawBattery; raw["Current Capacity"] = 21
    check(DeviceBattery.parse(raw, computerName: "Mac")?.critical == false, "21 percent battery is above the critical threshold")
    raw.removeValue(forKey: "Current Capacity")
    check(DeviceBattery.parse(raw, computerName: "Mac")?.percent == nil, "Unavailable battery is unknown, not zero")
    raw["Current Capacity"] = 255
    check(DeviceBattery.parse(raw, computerName: "Mac")?.percent == nil, "Invalid battery percentage is not shown or alerted")
    raw["Is Present"] = false
    check(DeviceBattery.parse(raw, computerName: "Mac") == nil, "Disconnected power sources are omitted")
    func batteryAt(_ percentage: Int, charging: Bool = false) -> DeviceBattery {
        DeviceBattery(id: "device", name: "Device", percent: percentage, charging: charging, internalBattery: false, category: "Headphone")
    }
    var policy = BatteryAlertPolicy()
    check(policy.update([batteryAt(51)]).isEmpty, "No battery alert above 50 percent")
    check(policy.update([batteryAt(50)]).count == 1, "50 percent triggers one alert")
    check(policy.update([batteryAt(49)]).isEmpty, "Continuing discharge does not repeat alert")
    check(policy.update([batteryAt(51)]).isEmpty && policy.update([batteryAt(50)]).isEmpty, "Threshold fluctuation does not repeat alert")
    _ = policy.update([batteryAt(56)])
    check(policy.update([batteryAt(50)]).count == 1, "Recovery above 55 percent re-arms alert")
    var chargingPolicy = BatteryAlertPolicy()
    check(chargingPolicy.update([batteryAt(20, charging: true)]).isEmpty, "Charging device does not trigger low-battery alert")
    check(chargingPolicy.update([batteryAt(20)]).count == 1, "Unplugging an already-low device can alert")
    let payload: [String: Any] = ["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 8.0, "windowDurationMins": 10080, "resetsAt": 2000000000.0], "secondary": NSNull()]], "rateLimits": ["primary": ["usedPercent": 90.0]]]
    let quota = UsageSnapshot.codex(payload)
    check(quota.windows.count == 1 && quota.windows[0].remaining == 92, "Codex uses current bucket map and converts used to remaining")
    check(quota.windows[0].label == "7일 한도", "Codex reports actual window duration instead of assuming five hours")
    check(UsageSnapshot.codex(["rateLimits": ["primary": NSNull()]]).windows.isEmpty, "Missing quota is unavailable, not 100 percent")
    let exhausted = UsageWindow(id: "x", label: "x", used: 110, resetsAt: nil)
    check(exhausted.remaining == 0, "Exceeded quota is clamped to zero remaining")
    let claudePayload: [String: Any] = ["rate_limits": ["five_hour": ["used_percentage": 37.0, "resets_at": 2000000000.0], "seven_day": ["used_percentage": 12.0]], "context_window": ["used_percentage": 99], "transcript_path": "/private/conversation", "session_id": "private"]
    let claudeQuota = UsageSnapshot.claude(claudePayload, sampledAt: Date())
    check(claudeQuota.windows.map(\.remaining) == [63, 88], "Claude reads subscription limits, never context-window percentage")
    check(!ClaudeUsageLink.supported("2.1.4 (Claude Code)") && ClaudeUsageLink.supported("2.1.251 (Claude Code)"), "Claude integration enforces documented minimum version")
    do {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("notchwave-checks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let settings = temp.appendingPathComponent("settings.json"), record = temp.appendingPathComponent("record.json"), cache = temp.appendingPathComponent("usage.json")
        let original: [String: Any] = ["theme": "dark", "statusLine": ["type": "command", "command": "echo original"]]
        try ClaudeUsageLink.write(original, to: settings)
        try ClaudeUsageLink.install(settings: settings, record: record, executable: "/App Folder/Notchwave")
        let linked = try ClaudeUsageLink.object(settings)
        check(linked["theme"] as? String == "dark", "Claude integration preserves unrelated settings")
        check((linked["statusLine"] as? [String: Any])?["command"] as? String == "'/App Folder/Notchwave' --capture-claude-usage", "Claude command safely quotes paths containing spaces")
        try ClaudeUsageLink.install(settings: settings, record: record, executable: "/App Folder/Notchwave")
        try ClaudeUsageLink.uninstall(settings: settings, record: record)
        let restored = try ClaudeUsageLink.object(settings)
        check((restored["statusLine"] as? [String: Any])?["command"] as? String == "echo original", "Repeated connection still restores the original status line")
        try ClaudeUsageLink.capture(JSONSerialization.data(withJSONObject: claudePayload), cache: cache)
        let safeCache = try ClaudeUsageLink.object(cache)
        check(Set(safeCache.keys) == ["rate_limits", "sampledAt"], "Claude cache excludes transcripts, session IDs and all unrelated data")
        let firstCache = try Data(contentsOf: cache)
        try ClaudeUsageLink.capture(Data("{}".utf8), cache: cache)
        let retainedCache = try Data(contentsOf: cache)
        check(retainedCache == firstCache, "Missing Claude quota does not erase a known sample")
    } catch { fatalError("Utility integration checks failed: \(error)") }
    var chargingEvents = ChargingAlertPolicy()
    check(chargingEvents.update([batteryAt(42, charging: true)]).isEmpty, "Launch does not announce already charging devices")
    check(chargingEvents.update([batteryAt(42)]).isEmpty, "Unplugging is not a charging notification")
    check(chargingEvents.update([batteryAt(42, charging: true)]).count == 1, "Plugging in announces charging once")
    check(chargingEvents.update([batteryAt(43, charging: true)]).isEmpty, "Charging percentage updates do not repeat notification")
    _ = chargingEvents.update([batteryAt(44)])
    check(chargingEvents.update([batteryAt(44, charging: true)]).count == 1, "Unplugging and reconnecting re-arms charging notification")
    _ = chargingEvents.update([])
    check(chargingEvents.update([batteryAt(45, charging: true)]).count == 1, "Newly connected charging accessory is announced")
    check(batteryAt(42, charging: true).color == batteryAt(42).color, "Charging preserves yellow battery color")
    check(batteryAt(20, charging: true).color == batteryAt(20).color, "Charging preserves critical red battery color")
    check(glass.hitRect(expanded: false, active: true, alert: true, chargingAlert: true).height == 56, "Charging ring and click target have matching height")

    let hookPayload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "test-session", "cwd": "/private/Example Project", "tool_name": "Bash", "tool_input": ["command": "SECRET COMMAND"], "last_assistant_message": "PRIVATE RESPONSE", "transcript_path": "/private/transcript"]
    let permission = AIEvent.decodeHook(hookPayload, provider: .claude, environment: ["TERM_PROGRAM": "ghostty"], now: date)!
    check(permission.targetBundleID == "com.mitchellh.ghostty", "CLI notifications return to the originating terminal")
    check(permission.project == "Example Project" && permission.tool == "명령 실행", "Notifications keep only short display metadata")
    let codexEvent = AIEvent.decodeHook(hookPayload, provider: .codex, environment: ["__CFBundleIdentifier": "com.openai.codex", "TERM_PROGRAM": "ghostty"], now: date)!
    check(codexEvent.targetBundleID == "com.openai.codex", "Desktop host takes precedence over inherited terminal environment")
    check(AIEvent.decodeHook(["hook_event_name": "Notification", "session_id": "s", "notification_type": "idle_prompt"], provider: .claude) == nil, "Idle notifications are not mistaken for task completion")
    check(AIEvent.decodeHook(["hook_event_name": "Stop"], provider: .codex) == nil, "Unroutable hook input is ignored")
    let sessionID = "11111111-1111-4111-8111-111111111111"
    let turnID = "22222222-2222-4222-8222-222222222222"
    let logDate = ISO8601DateFormatter(); logDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func completionLine(_ time: Date, turn: String = "22222222-2222-4222-8222-222222222222", focused: Bool = false) -> String {
        "\(logDate.string(from: time)) info [electron-message-handler] [desktop-notifications] received turn-complete conversationId=\(sessionID) rendererWindowFocused=\(focused) turnId=\(turn)"
    }
    let desktopEvent = CodexCompletionMonitor.event(from: completionLine(date))!
    check(desktopEvent.session == sessionID && desktopEvent.id == UUID(uuidString: turnID), "Background desktop completion carries the original thread and turn IDs")
    check(CodexCompletionMonitor.event(from: completionLine(date, focused: true)) != nil, "Completion detection is independent of which app has focus")
    check(CodexCompletionMonitor.event(from: completionLine(date).replacingOccurrences(of: "received turn-complete", with: "show notification")) == nil, "Delivery and renderer messages do not create extra completion alerts")
    check(CodexCompletionMonitor.event(from: "ResizeObserver loop completed with undelivered notifications.") == nil, "Renderer errors are not mistaken for completions")
    check(CodexCompletionMonitor.event(from: completionLine(date, turn: "undefined")) == nil, "Incomplete routing metadata is ignored")
    let stopEvent = AIEvent.decodeHook(["hook_event_name": "Stop", "session_id": sessionID, "turn_id": turnID, "cwd": "/Project"], provider: .codex, now: date)!
    check(stopEvent.openingURL?.absoluteString == "codex://threads/" + sessionID, "Codex notifications link to the original conversation")
    check(permission.openingURL == nil, "Claude terminal notifications retain their existing app destination")
    check(CodexThreadMetadata.deepLink(session: "../settings") == nil, "Invalid session IDs cannot navigate to another app action")
    let remoteLink = CodexThreadMetadata.deepLink(session: sessionID, hostID: "remote-ssh-discovered:example&prompt=oops")!
    let remoteParts = URLComponents(url: remoteLink, resolvingAgainstBaseURL: false)!
    check(remoteParts.queryItems?.count == 1 && remoteParts.queryItems?.first?.value == "remote-ssh-discovered:example&prompt=oops", "Remote host IDs are encoded as a single routing parameter")
    check(CodexThreadMetadata.cleanTitle("  한글 대화\n제목\t ") == "한글 대화 제목", "Conversation titles remain readable in one-line alerts")
    check(CodexThreadMetadata.cleanTitle(String(repeating: "가", count: 300))?.count == 200, "Long titles have a bounded display size")
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notchwave-title-checks-" + UUID().uuidString)
        let sqliteFolder = folder.appendingPathComponent("sqlite")
        try FileManager.default.createDirectory(at: sqliteFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = sqliteFolder.appendingPathComponent("codex.db")
        var db: OpaquePointer?
        check(sqlite3_open(database.path, &db) == SQLITE_OK, "Create isolated catalog fixture")
        defer { sqlite3_close(db) }
        let schema = "CREATE TABLE local_thread_catalog (thread_id TEXT, display_title TEXT, host_id TEXT, missing_candidate INTEGER, source_updated_at REAL);"
        let row = "INSERT INTO local_thread_catalog VALUES ('\(sessionID)', '실제 대화 제목', 'remote-ssh-discovered:test-host', 0, 1000);"
        check(sqlite3_exec(db, schema + row, nil, nil, nil) == SQLITE_OK, "Fixture stores display titles separately from messages")
        let reader = CodexThreadMetadataReader(home: folder)
        let metadata = reader.lookup(session: sessionID)
        check(metadata?.title == "실제 대화 제목" && metadata?.hostID == "remote-ssh-discovered:test-host", "Remote titles and exact host are resolved from the desktop catalog")
        check(reader.lookup(session: "' OR 1=1 --") == nil, "Invalid identifiers never query arbitrary catalog entries")
        check(sqlite3_exec(db, "UPDATE local_thread_catalog SET display_title = '변경된 제목', host_id = 'local';", nil, nil, nil) == SQLITE_OK, "Update fixture to model a renamed and moved conversation")
        check(reader.lookup(session: sessionID)?.title == "변경된 제목" && reader.lookup(session: sessionID)?.hostID == "local", "Renames and handoffs are re-read at click time")
        var titledQueue = AIAlertQueue()
        titledQueue.receive(stopEvent, now: date)
        titledQueue.updateConversation(metadata!, session: sessionID)
        check(titledQueue.banner?.conversationTitle == "실제 대화 제목" && titledQueue.items.first?.hostID == metadata?.hostID, "Late titles update both banner and stored notification")
        titledQueue.tick(now: date.addingTimeInterval(6))
        check(titledQueue.banner == nil && titledQueue.items.count == 1, "Title refresh does not replay the notification or extend its timeout")
        check(sqlite3_exec(db, "UPDATE local_thread_catalog SET missing_candidate = 1;", nil, nil, nil) == SQLITE_OK, "Mark stale fixture entry missing")
        check(reader.lookup(session: sessionID) == nil, "Removed catalog entries are not used for routing")
        let index = "{\"id\":\"\(sessionID)\",\"thread_name\":\"이전 버전 대화\"}\n"
        try Data(index.utf8).write(to: folder.appendingPathComponent("session_index.jsonl"))
        check(reader.lookup(session: sessionID)?.title == "이전 버전 대화" && reader.lookup(session: sessionID)?.hostID == nil, "Older title index provides a name without forcing a stale local host")
        let nonexistent = folder.appendingPathComponent("absent.db")
        check(CodexThreadMetadataReader.readCatalog(nonexistent, session: sessionID) == nil && !FileManager.default.fileExists(atPath: nonexistent.path), "Read-only lookup never creates or changes a Codex database")
        let oldData = try JSONEncoder().encode(stopEvent)
        var oldObject = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
        oldObject.removeValue(forKey: "conversationTitle"); oldObject.removeValue(forKey: "hostID")
        let decodedOld = try JSONDecoder().decode(AIEvent.self, from: JSONSerialization.data(withJSONObject: oldObject))
        check(decodedOld.conversationTitle == nil && decodedOld.openingURL == stopEvent.openingURL, "Existing inbox notifications remain compatible")
    } catch { fatalError("Conversation title and routing checks failed: \(error)") }
    runCodexReadStateChecks { check($0, $1) }
    runRemoteClaudeChecks { check($0, $1) }
    var deduplicated = AIAlertQueue()
    deduplicated.receive(stopEvent, now: date)
    deduplicated.receive(desktopEvent, now: date)
    check(deduplicated.items.count == 1, "Local hook plus desktop completion displays one notification")
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notchwave-log-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.log"), rotated = folder.appendingPathComponent("second.log")
        try Data((completionLine(date.addingTimeInterval(-10)) + "\n").utf8).write(to: first)
        let monitor = CodexCompletionMonitor(discover: { [first, rotated].filter { FileManager.default.fileExists(atPath: $0.path) } })
        check(monitor.poll(now: date).isEmpty, "Startup does not replay old desktop notifications")
        let line = Data((completionLine(date.addingTimeInterval(1)) + "\n").utf8)
        let handle = try FileHandle(forWritingTo: first)
        try handle.seekToEnd(); try handle.write(contentsOf: line.prefix(50))
        check(monitor.poll(now: date.addingTimeInterval(1)).isEmpty, "Incomplete log writes wait for the rest of the line")
        try handle.write(contentsOf: line.dropFirst(50)); try handle.close()
        let delivered = monitor.poll(now: date.addingTimeInterval(2))
        check(delivered.count == 1 && delivered[0].id == desktopEvent.id, "Appended background completion reaches the alert transport")
        check(monitor.poll(now: date.addingTimeInterval(3)).isEmpty, "The same bytes are not read twice")
        let nextTurn = "33333333-3333-4333-8333-333333333333"
        try Data((completionLine(date.addingTimeInterval(4), turn: nextTurn) + "\n").utf8).write(to: rotated)
        check(monitor.poll(now: date.addingTimeInterval(6)).first?.id == UUID(uuidString: nextTurn), "Log rotation continues delivering completions")
        try Data((completionLine(date.addingTimeInterval(7)) + "\n").utf8).write(to: first)
        check(monitor.poll(now: date.addingTimeInterval(8)).count == 1, "Truncated log files recover without a restart")
        let append = try FileHandle(forWritingTo: first); try append.seekToEnd()
        try append.write(contentsOf: Data((completionLine(date.addingTimeInterval(-100)) + "\n").utf8)); try append.close()
        check(monitor.poll(now: date.addingTimeInterval(9)).isEmpty, "Stale completion records are not replayed")
    } catch { fatalError("Desktop completion transport checks failed: \(error)") }
    var alerts = AIAlertQueue()
    alerts.receive(permission, now: date)
    check(alerts.pendingCount == 1 && alerts.banner?.id == permission.id, "Approval request shows a banner and persistent pending badge")
    alerts.receive(permission, now: date)
    check(alerts.items.count == 1, "Repeated delivery of the same event is ignored")
    var delayed = permission; delayed.id = UUID(); delayed.createdAt = date.addingTimeInterval(6)
    alerts.receive(delayed, now: delayed.createdAt)
    alerts.tick(now: delayed.createdAt)
    check(alerts.pendingCount == 1 && alerts.banner == nil, "Delayed permission notification does not replay the same banner")
    var resumed = permission; resumed.id = UUID(); resumed.kind = .resumed; resumed.createdAt = date.addingTimeInterval(7); resumed.toolKey = "Read"
    alerts.receive(resumed, now: resumed.createdAt)
    check(alerts.pendingCount == 1, "Other parallel tool completions do not clear a pending approval")
    resumed.id = UUID(); resumed.toolKey = "Bash"; resumed.createdAt = date.addingTimeInterval(8)
    alerts.receive(resumed, now: resumed.createdAt)
    check(alerts.pendingCount == 0, "Resuming the requested tool clears its pending approval")
    var complete = permission; complete.id = UUID(); complete.kind = .completed; complete.createdAt = date.addingTimeInterval(9)
    alerts.receive(complete, now: complete.createdAt)
    alerts.tick(now: date.addingTimeInterval(15))
    check(alerts.banner == nil && alerts.items.count == 1, "Completion banner ends after five seconds but stays in history")
    check(alerts.storedCount == 1 && alerts.pendingCount == 0, "A completed response keeps a capsule count after its banner expires")
    alerts.receive(permission, now: date.addingTimeInterval(16))
    check(alerts.pendingCount == 0, "Out-of-order older permission cannot resurrect a resolved request")
    complete.id = UUID(); complete.session = "other-session"; complete.createdAt = date.addingTimeInterval(17)
    alerts.receive(complete, now: complete.createdAt)
    alerts.tick(now: date.addingTimeInterval(23), paused: true)
    check(alerts.banner != nil, "Battery presentation pauses AI banner expiry")
    alerts.tick(now: date.addingTimeInterval(29))
    check(alerts.banner == nil, "AI banner expires after battery presentation ends")
    var idleAlerts = AIAlertQueue()
    var idleEvent = codexEvent
    idleEvent.kind = .completed
    idleAlerts.receive(idleEvent, now: date, keepCodexVisible: true)
    idleAlerts.tick(now: date.addingTimeInterval(3601))
    check(idleAlerts.banner == nil && idleAlerts.idleCodexAlert?.id == idleEvent.id, "Idle Codex response stays visible beyond banner and history timeouts")
    var newerIdle = idleEvent; newerIdle.id = UUID(); newerIdle.session = "newer"; newerIdle.createdAt = date.addingTimeInterval(3602)
    idleAlerts.receive(newerIdle, now: newerIdle.createdAt, keepCodexVisible: true)
    check(idleAlerts.idleCodexAlert?.id == newerIdle.id, "A new idle Codex notification replaces the previous one")
    idleAlerts.acknowledge(idleEvent.id)
    check(idleAlerts.idleCodexAlert?.id == newerIdle.id, "Opening an older notification does not hide a newer persistent alert")
    idleAlerts.acknowledge(newerIdle.id)
    check(idleAlerts.idleCodexAlert == nil && idleAlerts.banner == nil, "Acknowledging the current alert clears persistent presentation")
    var idlePermission = codexEvent; idlePermission.id = UUID(); idlePermission.createdAt = date.addingTimeInterval(3603)
    idleAlerts.receive(idlePermission, now: idlePermission.createdAt, keepCodexVisible: true)
    idleAlerts.acknowledge(idlePermission.id)
    check(idleAlerts.idleCodexAlert == nil && idleAlerts.pendingCount == 1, "Acknowledged approval still retains its pending badge")
    var idleResume = idlePermission; idleResume.id = UUID(); idleResume.kind = .resumed; idleResume.createdAt = date.addingTimeInterval(3604)
    idleAlerts.receive(idleResume, now: idleResume.createdAt, keepCodexVisible: true)
    check(idleAlerts.pendingCount == 0 && idleAlerts.idleCodexAlert == nil, "Resuming a Codex tool removes its pinned approval")
    var playingAlerts = AIAlertQueue()
    playingAlerts.receive(idleEvent, now: date)
    playingAlerts.tick(now: date.addingTimeInterval(6))
    check(playingAlerts.banner == nil && playingAlerts.idleCodexAlert == nil, "Codex completion during music remains a temporary banner")
    var claudeAlerts = AIAlertQueue()
    claudeAlerts.receive(permission, now: date, keepCodexVisible: true)
    claudeAlerts.tick(now: date.addingTimeInterval(6))
    check(claudeAlerts.idleCodexAlert == nil, "Claude retains its existing temporary banner behavior")
    var remoteCompleted = complete
    remoteCompleted.provider = .claude; remoteCompleted.remoteHost = "nutella2"
    remoteCompleted.createdAt = date.addingTimeInterval(7)
    claudeAlerts.receive(remoteCompleted, now: remoteCompleted.createdAt)
    claudeAlerts.tick(now: date.addingTimeInterval(13))
    check(claudeAlerts.banner == nil && claudeAlerts.storedCount == 2 && claudeAlerts.pendingCount == 1,
          "Remote completion and local approval both remain in the capsule count after banners expire")
    claudeAlerts.dismiss(remoteCompleted.id)
    check(claudeAlerts.storedCount == 1, "Reading or dismissing one completion leaves the other alert counted")
    var clearedAlerts = AIAlertQueue()
    clearedAlerts.receive(idleEvent, now: date, keepCodexVisible: true)
    clearedAlerts.receive(permission, now: date)
    check(clearedAlerts.items.count == 2 && clearedAlerts.pendingCount == 1, "Clear fixture includes completion and approval notifications")
    clearedAlerts.clearAll()
    check(clearedAlerts.items.isEmpty && clearedAlerts.pendingCount == 0, "Clear removes approvals as well as completed notifications and their badges")
    check(clearedAlerts.banner == nil && clearedAlerts.idleCodexAlert == nil, "Clear removes active and retained banners")
    clearedAlerts.tick(now: date.addingTimeInterval(6))
    check(clearedAlerts.banner == nil, "Queued notifications do not appear after clear")
    clearedAlerts.receive(permission, now: date.addingTimeInterval(7))
    clearedAlerts.receive(idleEvent, now: date.addingTimeInterval(7), keepCodexVisible: true)
    check(clearedAlerts.items.isEmpty, "Duplicate deliveries cannot restore cleared notifications")
    var freshPermission = permission; freshPermission.id = UUID(); freshPermission.createdAt = date.addingTimeInterval(8)
    clearedAlerts.receive(freshPermission, now: freshPermission.createdAt)
    check(clearedAlerts.pendingCount == 1 && clearedAlerts.banner?.id == freshPermission.id, "A new approval request still arrives after clear")
    let clearBridge = AIAlertBridge(demo: true)
    clearBridge.preview()
    clearBridge.preview(permission: true)
    clearBridge.clearAll()
    check(clearBridge.items.isEmpty && clearBridge.storedCount == 0 && clearBridge.pendingCount == 0 && clearBridge.banner == nil && !clearBridge.isEmphasized, "Clear button action updates inbox, badges and arrival presentation together")
    let bridge = AIAlertBridge(demo: true)
    bridge.preview()
    bridge.poll(now: Date().addingTimeInterval(6))
    check(bridge.banner?.provider == .codex, "Bridge presents the retained Codex alert after five seconds without music")
    bridge.updateMusicVisibility(visible: true)
    check(bridge.banner == nil, "Starting music returns the capsule to playback")
    check(bridge.storedCount == 1, "Music keeps the stored completion count when it replaces a retained banner")
    bridge.updateMusicVisibility(visible: false)
    check(bridge.banner == nil, "Closing Spotify does not resurrect the previously hidden Codex alert")
    check(bridge.storedCount == 1, "The completion count remains when Spotify closes")
    if let event = bridge.items.first { bridge.dismiss(event) }
    check(bridge.storedCount == 0, "Removing the last notification clears the capsule count")
    let pausedPlayer = SpotifyBridge()
    pausedPlayer.setDemo(true)
    let pausedAlerts = AIAlertBridge(demo: true)
    pausedPlayer.send(.toggle)
    check(pausedPlayer.active && pausedPlayer.track?.playing == false, "Pausing preserves the track used by the collapsed music capsule")
    pausedAlerts.updateMusicVisibility(visible: pausedPlayer.active)
    pausedAlerts.preview()
    pausedAlerts.poll(now: Date().addingTimeInterval(6))
    check(pausedAlerts.musicVisible && pausedAlerts.banner == nil && pausedAlerts.storedCount == 1,
          "An alert received while Spotify is paused expires back to music and keeps its badge")
    pausedPlayer.send(.toggle)
    pausedAlerts.updateMusicVisibility(visible: pausedPlayer.active)
    check(pausedPlayer.active && pausedPlayer.track?.playing == true && pausedAlerts.banner == nil,
          "Resuming Spotify keeps the same music capsule without resurrecting the alert")
    pausedPlayer.track = nil // Spotify refresh clears its track when the process exits.
    pausedAlerts.updateMusicVisibility(visible: pausedPlayer.active)
    check(!pausedPlayer.active && !pausedAlerts.musicVisible, "Closing Spotify releases the capsule's music presentation")
    var terminalCodex = idleEvent; terminalCodex.targetBundleID = "com.mitchellh.ghostty"
    check(terminalCodex.openingBundleID == "com.openai.codex", "Codex notification clicks always target the desktop app, not an inherited terminal")
    check(permission.openingBundleID == "com.mitchellh.ghostty", "Claude preserves its originating app routing")
    var arrival = AIAlertArrival()
    check(arrival.update(idleEvent, obscured: false, now: date), "First arrival immediately enlarges the notification")
    check(arrival.update(idleEvent, obscured: false, now: date.addingTimeInterval(2)), "Arrival remains prominent long enough to notice and click")
    check(!arrival.update(idleEvent, obscured: false, now: date.addingTimeInterval(2.6)), "Arrival contracts after two and a half seconds")
    check(!arrival.update(idleEvent, obscured: false, now: date.addingTimeInterval(7)), "Retained idle Codex banner does not pulse repeatedly")
    var anotherArrival = idleEvent; anotherArrival.id = UUID()
    check(!arrival.update(anotherArrival, obscured: true, now: date.addingTimeInterval(8)), "Battery notification does not consume a hidden AI arrival")
    check(arrival.update(anotherArrival, obscured: false, now: date.addingTimeInterval(16)), "AI enlargement starts when the battery notification finishes")
    let prominent = glass.hitRect(expanded: false, active: false, alert: true, aiAlertEmphasized: true)
    check(prominent.height == 56 && prominent.width == 354, "Enlarged capsule matches the charging notification height")
    check(prominent.contains(NSPoint(x: prominent.midX, y: prominent.minY + 3)), "Lower area of enlarged notification is clickable")
    check(glass.windowFrame.contains(prominent), "Enlarged notification stays within the hosting window")
    do {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("notchwave-hook-checks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let settings = temp.appendingPathComponent("settings.json")
        let otherHook: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "echo existing"]]]
        let original: [String: Any] = ["statusLine": ["type": "command", "command": "original status"], "permissions": ["allow": ["Read"]], "hooks": ["Stop": [otherHook]]]
        try ClaudeUsageLink.write(original, to: settings)
        let executable = "/Example App's Folder/Notchwave.app/Contents/MacOS/Notchwave"
        for _ in 0..<2 { try AIHookLink.setEnabled(true, provider: .claude, at: settings, executable: executable) }
        let linked = try ClaudeUsageLink.object(settings)
        let hooks = linked["hooks"] as! [String: Any]
        check((hooks["Stop"] as! [[String: Any]]).count == 2, "Reconnecting hooks is idempotent and preserves existing hooks")
        check((linked["statusLine"] as! NSDictionary).isEqual(to: original["statusLine"] as! [String: Any]), "Notification setup preserves Claude quota status line")
        check((linked["permissions"] as! NSDictionary).isEqual(to: original["permissions"] as! [String: Any]), "Notification setup never changes permission policy")
        check(AIHookLink.configured(.claude, at: settings), "Connection status requires completion and approval hooks")
        try AIHookLink.setEnabled(false, provider: .claude, at: settings, executable: executable)
        let restored = try ClaudeUsageLink.object(settings)
        check((restored as NSDictionary).isEqual(to: original), "Disconnect removes only Notchwave hooks")
        let malformed: [String: Any] = ["hooks": ["Stop": "invalid"]]
        check((try? AIHookLink.updated(malformed, provider: .codex, executable: executable, enabled: true)) == nil, "Malformed existing hooks are rejected without replacement")
        try AIHookLink.capture(hookPayload, provider: .claude, at: temp.appendingPathComponent("Inbox"), environment: [:])
        let files = try FileManager.default.contentsOfDirectory(at: temp.appendingPathComponent("Inbox"), includingPropertiesForKeys: nil)
        let encoded = try String(contentsOf: files[0], encoding: .utf8)
        check(!encoded.contains("SECRET") && !encoded.contains("PRIVATE") && !encoded.contains("transcript"), "Stored alerts exclude commands, final responses and transcripts")
        let decoded = try JSONDecoder().decode(AIEvent.self, from: Data(contentsOf: files[0]))
        check(decoded.kind == .permission && decoded.project == "Example Project", "Actual helper inbox transport preserves notification metadata")
    } catch { fatalError("AI alert checks failed: \(error)") }
    runClaudeUsageChecks { check($0, $1) }
    print("PASS: \(count) checks (playback, calendar, battery transitions, geometry, usage, AI hook setup and notification delivery).")
}
