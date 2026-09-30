import AppKit
import EventKit
import SwiftUI

struct CalendarEntry: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let calendarName: String
    let color: NSColor
    let location: String
    var calendarID = ""
    var calendarItemID = ""
    var lastModified: Date?
    var notes = ""
    var editable = true
    var recurring = false
    var hasAttendees = false

    func matchesRevision(_ other: CalendarEntry) -> Bool {
        calendarItemID == other.calendarItemID && start == other.start && end == other.end
        && title == other.title && allDay == other.allDay && calendarID == other.calendarID
        && notes == other.notes && location == other.location && lastModified == other.lastModified
    }
}

struct DaySegment: Identifiable {
    let event: CalendarEntry
    let startMinute: Double
    let endMinute: Double
    var lane = 0
    var laneCount = 1
    var id: String { event.id }
    // Match collision detection to the minimum visible block height.
    var displayEnd: Double { min(1440, max(endMinute, startMinute + 30)) }
}

enum WeekLayout {
    static func entries(_ events: [CalendarEntry], day: Date, calendar: Calendar) -> [CalendarEntry] {
        events.filter { overlaps($0, day: day, calendar: calendar) }.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }

    static func nextEventID(_ events: [CalendarEntry], after date: Date) -> String? {
        events.filter { !$0.allDay && $0.start >= date }.min { $0.start < $1.start }?.id
    }

    static func start(containing date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func days(from start: Date, calendar: Calendar) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func overlaps(_ event: CalendarEntry, day: Date, calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return false }
        return event.start < end && event.end > start
    }

    static func segments(_ events: [CalendarEntry], day: Date, calendar: Calendar) -> [DaySegment] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        func minute(_ date: Date) -> Double {
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        }
        var result = events.filter { !$0.allDay && overlaps($0, day: day, calendar: calendar) }.map { event in
            let from = event.start <= start ? 0 : minute(event.start)
            let to = event.end >= end ? 1440 : minute(event.end)
            return DaySegment(event: event, startMinute: from, endMinute: max(from + 1, to))
        }.sorted {
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            if $0.endMinute != $1.endMinute { return $0.endMinute > $1.endMinute }
            return $0.id < $1.id
        }
        var groupStart = 0
        while groupStart < result.count {
            var groupEnd = groupStart + 1
            var latestEnd = result[groupStart].displayEnd
            while groupEnd < result.count && result[groupEnd].startMinute < latestEnd {
                latestEnd = max(latestEnd, result[groupEnd].displayEnd)
                groupEnd += 1
            }
            var laneEnds: [Double] = []
            for index in groupStart..<groupEnd {
                let lane = laneEnds.firstIndex(where: { $0 <= result[index].startMinute }) ?? laneEnds.count
                if lane == laneEnds.count { laneEnds.append(result[index].displayEnd) }
                else { laneEnds[lane] = result[index].displayEnd }
                result[index].lane = lane
            }
            for index in groupStart..<groupEnd { result[index].laneCount = laneEnds.count }
            groupStart = groupEnd
        }
        return result
    }
}

// EventKit objects never leave this reader. Its serial queue owns every store operation;
// callers receive immutable display data and return to the main actor before publishing it.
private final class CalendarReader: @unchecked Sendable {
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "app.notchwave.calendar", qos: .userInitiated)

    func requestAccess(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        queue.async { [self] in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents(completion: completion)
            } else {
                store.requestAccess(to: .event, completion: completion)
            }
        }
    }

    private func entry(_ event: EKEvent) -> CalendarEntry {
        CalendarEntry(id: (event.eventIdentifier ?? event.calendarItemIdentifier) + "_\(event.startDate.timeIntervalSince1970)",
                      title: event.title?.isEmpty == false ? event.title! : "제목 없는 일정",
                      start: event.startDate, end: max(event.endDate, event.startDate.addingTimeInterval(60)),
                      allDay: event.isAllDay, calendarName: event.calendar.title,
                      color: NSColor(cgColor: event.calendar.cgColor) ?? .systemBlue, location: event.location ?? "",
                      calendarID: event.calendar.calendarIdentifier, calendarItemID: event.calendarItemIdentifier,
                      lastModified: event.lastModifiedDate, notes: event.notes ?? "",
                      editable: event.calendar.allowsContentModifications && (!event.hasAttendees || event.organizer?.isCurrentUser == true),
                      recurring: event.hasRecurrenceRules || event.isDetached, hasAttendees: event.hasAttendees)
    }

    private func choices() -> [CalendarChoice] {
        store.calendars(for: .event).map {
            CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title,
                           color: NSColor(cgColor: $0.cgColor) ?? .systemBlue, writable: $0.allowsContentModifications)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func fetch(start: Date, end: Date, completion: @escaping @Sendable (CalendarSnapshot) -> Void) {
        queue.async { [self] in
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let values = store.events(matching: predicate).filter { $0.status != .canceled }.map(entry).sorted { $0.start < $1.start }
            completion(CalendarSnapshot(events: values, calendars: choices(), defaultCalendarID: store.defaultCalendarForNewEvents?.calendarIdentifier))
        }
    }

    func save(_ form: EventForm, calendar: Calendar, completion: @escaping @Sendable (Result<CalendarEntry, CalendarWriteError>) -> Void) {
        queue.async { [self] in
            do {
                if let message = form.validation(calendar: calendar, choices: choices()) { throw CalendarWriteError(message: message) }
                guard let target = store.calendar(withIdentifier: form.calendarID), target.allowsContentModifications,
                      let dates = form.dates(calendar: calendar) else {
                    throw CalendarWriteError(message: "이 캘린더에 저장할 수 없습니다. 권한과 캘린더 상태를 확인해 주세요.")
                }
                let event: EKEvent
                if let original = form.original {
                    // Resolve the exact occurrence. event(withIdentifier:) may return the first recurrence.
                    let predicate = store.predicateForEvents(withStart: original.start.addingTimeInterval(-1),
                                                            end: original.end.addingTimeInterval(1), calendars: nil)
                    guard let current = store.events(matching: predicate).first(where: {
                        $0.calendarItemIdentifier == original.calendarItemID && $0.startDate == original.start && $0.status != .canceled
                    }) else {
                        throw CalendarWriteError(message: "원래 일정이 이동되거나 삭제되었습니다. 취소 후 최신 일정을 다시 열어 주세요.")
                    }
                    let latest = entry(current)
                    guard latest.editable else { throw CalendarWriteError(message: "이 일정은 현재 편집할 수 없습니다. 캘린더 앱에서 확인해 주세요.") }
                    guard original.matchesRevision(latest) else {
                        throw CalendarWriteError(message: "다른 곳에서 일정이 변경되었습니다. 취소 후 최신 일정을 다시 열어 주세요.")
                    }
                    if (latest.recurring || latest.hasAttendees) && form.calendarID != latest.calendarID {
                        throw CalendarWriteError(message: "반복 일정과 참석자가 있는 일정은 캘린더를 옮길 수 없습니다.")
                    }
                    event = current
                } else {
                    event = EKEvent(eventStore: store)
                }
                // Keep recurrence rules, alarms, attendees, URL and time zone on existing events.
                event.calendar = target
                event.title = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
                event.isAllDay = form.allDay
                event.startDate = dates.start
                event.endDate = dates.end
                event.location = form.location.isEmpty ? nil : form.location
                event.notes = form.notes.isEmpty ? nil : form.notes
                try store.save(event, span: .thisEvent, commit: true)
                completion(.success(entry(event)))
            } catch {
                store.reset()
                let failure = (error as? CalendarWriteError) ?? CalendarWriteError(message: "저장하지 못했습니다. " + error.localizedDescription)
                completion(.failure(failure))
            }
        }
    }
}

@MainActor final class CalendarBridge: ObservableObject {
    enum Access { case needsPermission, ready, denied, restricted, failed }
    enum Presentation: String, CaseIterable {
        case summary = "주간 요약"
        case timetable = "시간표"
        var symbol: String {
            switch self { case .summary: return "rectangle.split.3x1"; case .timetable: return "clock" }
        }
    }
    @Published private(set) var access: Access = .needsPermission
    @Published private(set) var events: [CalendarEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var requesting = false
    @Published private(set) var demo = false
    @Published private(set) var weekStart: Date
    @Published private(set) var calendars: [CalendarChoice] = []
    @Published private(set) var draft: EventDraft?
    @Published private(set) var saving = false
    @Published private(set) var saveError: String?
    @Published private(set) var notice: String?
    private var defaultCalendarID: String?
    private var demoEvents: [CalendarEntry] = []
    @Published var selection: CalendarEntry?
    @Published var selectedDay: Date?
    @Published var presentation: Presentation = .summary
    private(set) var calendar: Calendar
    private let reader = CalendarReader()
    private var observer: NSObjectProtocol?
    private var generation = 0

    init(demo: Bool = false) {
        calendar = .autoupdatingCurrent
        weekStart = WeekLayout.start(containing: Date(), calendar: calendar)
        if demo { setDemo(true) }
    }

    var days: [Date] { WeekLayout.days(from: weekStart, calendar: calendar) }
    var weekEnd: Date { calendar.date(byAdding: .day, value: 7, to: weekStart)! }
    var fetchStart: Date { weekStart }
    var fetchEnd: Date { weekEnd }
    var isCurrentPeriod: Bool { isThisWeek }
    var periodEvents: [CalendarEntry] { events }
    var writableCalendars: [CalendarChoice] { calendars.filter(\.writable) }
    var isThisWeek: Bool { Date() >= weekStart && Date() < weekEnd }
    var dayEvents: [CalendarEntry] {
        guard let day = selectedDay else { return [] }
        return WeekLayout.entries(events, day: day, calendar: calendar)
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func movePeriod(_ delta: Int) {
        weekStart = calendar.date(byAdding: .day, value: delta * 7, to: weekStart)!
        notice = nil
        selection = nil
        selectedDay = nil
        refresh()
    }

    func today() {
        weekStart = WeekLayout.start(containing: Date(), calendar: calendar)
        notice = nil
        selection = nil
        selectedDay = nil
        refresh()
    }

    func select(_ event: CalendarEntry) { selection = event; notice = nil }
    func selectDay(_ day: Date) {
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        selectedDay = isSelected ? nil : calendar.startOfDay(for: day)
        selection = nil
        notice = nil
    }
    func clearSelection() { selection = nil }
    func closeDetail() { selection = nil; selectedDay = nil }
    func show(_ presentation: Presentation) {
        guard self.presentation != presentation else { return }
        self.presentation = presentation
        closeDetail()
        refresh()
    }

    func beginCreate(on day: Date? = nil) {
        guard draft == nil, !saving else { return }
        guard !writableCalendars.isEmpty else { notice = "새 일정을 저장할 수 있는 캘린더가 없습니다."; return }
        let date = day ?? selectedDay ?? (isCurrentPeriod ? Date() : weekStart)
        let id = writableCalendars.first(where: { $0.id == defaultCalendarID })?.id ?? writableCalendars[0].id
        saveError = nil
        draft = EventDraft(EventForm(day: date, calendarID: id, calendar: calendar))
    }

    func beginEdit(_ event: CalendarEntry) {
        guard event.editable, draft == nil, !saving else { return }
        saveError = nil
        draft = EventDraft(EventForm(event: event, calendar: calendar))
    }

    func cancelEditing() {
        guard !saving else { return }
        draft = nil
        saveError = nil
        refresh()
    }

    func saveDraft() {
        guard let draft, !saving else { return }
        let form = draft.form
        if let message = form.validation(calendar: calendar, choices: calendars) { saveError = message; return }
        saveError = nil
        saving = true
        if demo {
            let choice = writableCalendars.first { $0.id == form.calendarID }!
            let dates = form.dates(calendar: calendar)!
            let entry = CalendarEntry(id: form.original?.id ?? UUID().uuidString, title: form.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                      start: dates.start, end: dates.end, allDay: form.allDay, calendarName: choice.title,
                                      color: choice.color, location: form.location, calendarID: choice.id, notes: form.notes)
            demoEvents.removeAll { $0.id == entry.id }
            demoEvents.append(entry)
            finishSave(.success(entry))
        } else {
            guard currentAccess() == .ready else { saving = false; saveError = "캘린더 접근 권한이 없습니다. 시스템 설정에서 전체 접근을 허용해 주세요."; return }
            reader.save(form, calendar: calendar) { [weak self] result in
                Task { @MainActor in self?.finishSave(result) }
            }
        }
    }

    private func finishSave(_ result: Result<CalendarEntry, CalendarWriteError>) {
        saving = false
        switch result {
        case .success(let event):
            weekStart = WeekLayout.start(containing: event.start, calendar: calendar)
            selectedDay = calendar.startOfDay(for: event.start)
            selection = event
            draft = nil
            notice = "일정을 저장했습니다."
            refresh()
        case .failure(let error): saveError = error.message
        }
    }

    func setDemo(_ enabled: Bool) {
        guard draft == nil, !saving else { return }
        demo = enabled
        if enabled { demoEvents = sampleEvents() }
        notice = nil
        selection = nil
        selectedDay = nil
        refresh()
    }

    private func currentAccess() -> Access {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            if status == .fullAccess { return .ready }
        } else if status == .authorized { return .ready }
        if status == .restricted { return .restricted }
        if status == .denied { return .denied }
        return .needsPermission
    }

    func connect() {
        guard !requesting else { return }
        demo = false
        generation += 1
        let status = currentAccess()
        if status == .ready { refresh(); return }
        if status == .denied || status == .restricted { access = status; return }
        requesting = true
        NSApp.activate(ignoringOtherApps: true)
        let completion: @Sendable (Bool, Error?) -> Void = { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.requesting = false
                if error != nil && self.currentAccess() == .needsPermission { self.access = .failed }
                else { self.refresh() }
            }
        }
        reader.requestAccess(completion: completion)
    }

    func refresh() {
        generation += 1
        let token = generation
        if demo {
            loading = false
            access = .ready
            calendars = [CalendarChoice(id: "demo-work", title: "업무", source: "예시", color: .systemBlue, writable: true),
                         CalendarChoice(id: "demo-personal", title: "개인", source: "예시", color: .systemOrange, writable: true)]
            defaultCalendarID = "demo-work"
            events = demoEvents.filter { $0.start < fetchEnd && $0.end > fetchStart }.sorted { $0.start < $1.start }
            if let selection { self.selection = events.first { $0.id == selection.id } }
            return
        }
        access = currentAccess()
        guard access == .ready else {
            loading = false
            events = []
            calendars = []
            closeDetail()
            return
        }
        loading = true
        reader.fetch(start: fetchStart, end: fetchEnd) { [weak self] values in
            Task { @MainActor in
                guard let self, self.generation == token, !self.demo else { return }
                self.loading = false
                guard self.currentAccess() == .ready else { self.refresh(); return }
                self.events = values.events
                self.calendars = values.calendars
                self.defaultCalendarID = values.defaultCalendarID
                if let selection = self.selection { self.selection = values.events.first { $0.id == selection.id } }
            }
        }
    }

    func openCalendar() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    private func sampleEvents() -> [CalendarEntry] {
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: day, to: weekStart)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        }
        func event(_ id: String, _ title: String, _ day: Int, _ hour: Int, _ duration: Double, _ color: NSColor, _ name: String, _ location: String = "") -> CalendarEntry {
            let start = date(day, hour)
            return CalendarEntry(id: id, title: title, start: start, end: start.addingTimeInterval(duration * 3600), allDay: false, calendarName: name, color: color, location: location, calendarID: name == "업무" ? "demo-work" : "demo-personal")
        }
        return [
            event("walk", "아침 산책", 0, 9, 0.75, .systemGreen, "개인", "공원"),
            event("plan", "이번 주 계획", 1, 9, 1, .systemBlue, "업무"),
            event("design", "디자인 리뷰", 1, 11, 1.5, .systemPurple, "업무", "회의실 A"),
            event("project", "프로젝트 미팅", 1, 14, 1, .systemBlue, "업무"),
            event("notes", "자료 정리", 1, 17, 0.5, .systemBlue, "업무"),
            event("dinner", "저녁 약속", 1, 20, 1.5, .systemOrange, "개인"),
            event("coffee", "커피 약속", 2, 10, 1, .systemOrange, "개인", "동네 카페"),
            event("focus", "집중 작업", 3, 9, 2, .systemBlue, "업무"),
            event("sync", "팀 미팅", 3, 10, 1, .systemPurple, "업무", "온라인"),
            event("lunch", "점심 약속", 4, 12, 1, .systemOrange, "개인"),
            event("review", "연구 미팅", 5, 14, 1, .systemBlue, "업무"),
            event("reading", "책 읽는 시간", 6, 10, 1.5, .systemGreen, "개인"),
            CalendarEntry(id: "allday", title: "프로젝트 마감", start: date(5, 0), end: date(6, 0), allDay: true, calendarName: "업무", color: .systemPurple, location: "", calendarID: "demo-work")
        ]
    }
}
