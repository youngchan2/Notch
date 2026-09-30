import AppKit
import SwiftUI

struct CalendarChoice: Identifiable {
    let id: String
    let title: String
    let source: String
    let color: NSColor
    let writable: Bool
}

struct CalendarSnapshot {
    let events: [CalendarEntry]
    let calendars: [CalendarChoice]
    let defaultCalendarID: String?
}

struct EventForm {
    var title: String
    var start: Date
    // All-day forms use an inclusive last day; EventKit uses an exclusive end.
    var end: Date
    var allDay: Bool
    var calendarID: String
    var location: String
    var notes: String
    var original: CalendarEntry?

    init(day: Date, calendarID: String, calendar: Calendar) {
        title = ""
        start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        end = calendar.date(byAdding: .hour, value: 1, to: start)!
        allDay = false
        self.calendarID = calendarID
        location = ""
        notes = ""
    }

    init(event: CalendarEntry, calendar: Calendar) {
        title = event.title
        start = event.start
        end = event.allDay ? calendar.date(byAdding: .day, value: -1, to: event.end)! : event.end
        allDay = event.allDay
        calendarID = event.calendarID
        location = event.location
        notes = event.notes
        original = event
    }

    func dates(calendar: Calendar) -> DateInterval? {
        let from = allDay ? calendar.startOfDay(for: start) : start
        let to = allDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))! : end
        guard to > from else { return nil }
        return DateInterval(start: from, end: to)
    }

    func validation(calendar: Calendar, choices: [CalendarChoice]) -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "일정 제목을 입력해 주세요." }
        if dates(calendar: calendar) == nil { return allDay ? "마지막 날은 시작일 이후여야 합니다." : "종료 시간은 시작 시간보다 늦어야 합니다." }
        if !choices.contains(where: { $0.id == calendarID && $0.writable }) { return "저장할 수 있는 캘린더를 선택해 주세요." }
        if original?.editable == false { return "이 일정은 편집할 수 없습니다." }
        return nil
    }
}

@MainActor final class EventDraft: ObservableObject, Identifiable {
    let id = UUID()
    @Published var form: EventForm
    init(_ form: EventForm) { self.form = form }
}

struct CalendarWriteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct EventEditorView: View {
    @ObservedObject var calendar: CalendarBridge
    @ObservedObject var draft: EventDraft
    @FocusState private var titleFocused: Bool
    private var creating: Bool { draft.form.original == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(creating ? "새 일정" : "일정 수정").font(.system(size: 18, weight: .semibold))
                    Text(calendar.demo ? "예시 일정만 변경됩니다." : "저장하면 Mac 캘린더에도 반영됩니다.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Button("취소") { calendar.cancelEditing() }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).padding(8)
                    .disabled(calendar.saving)
                Button(calendar.saving ? "저장 중…" : "저장") { calendar.saveDraft() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 19).padding(.vertical, 9)
                    .background(Color(red: 0.55, green: 0.7, blue: 1), in: Capsule())
                    .disabled(calendar.saving || validation != nil)
                    .accessibilityLabel("일정 저장")
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("일정 제목", text: $draft.form.title)
                        .textFieldStyle(.plain).font(.system(size: 17, weight: .medium))
                        .padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .focused($titleFocused).accessibilityLabel("일정 제목")
                    HStack(spacing: 16) {
                        Picker("캘린더", selection: $draft.form.calendarID) {
                            if draft.form.calendarID.isEmpty { Text("선택해 주세요").tag("") }
                            ForEach(calendar.writableCalendars) { choice in
                                Text(choice.title + (choice.source.isEmpty ? "" : " · " + choice.source)).tag(choice.id)
                            }
                        }.frame(maxWidth: .infinity).accessibilityLabel("저장할 캘린더")
                            .disabled(draft.form.original?.recurring == true || draft.form.original?.hasAttendees == true)
                        Toggle("종일", isOn: $draft.form.allDay).toggleStyle(.switch).controlSize(.small)
                            .frame(width: 90)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        dateField(draft.form.allDay ? "시작일" : "시작", date: $draft.form.start)
                        dateField(draft.form.allDay ? "마지막 날" : "종료", date: $draft.form.end)
                        Spacer(minLength: 0)
                    }
                    TextField("장소", text: $draft.form.location).textFieldStyle(.roundedBorder).accessibilityLabel("일정 장소")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("메모").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        TextEditor(text: $draft.form.notes).font(.system(size: 12))
                            .scrollContentBackground(.hidden).frame(height: 72)
                            .padding(7).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("일정 메모")
                    }
                    if draft.form.original?.recurring == true {
                        Text("반복 일정은 선택한 이번 회차만 수정합니다.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                    if draft.form.original?.hasAttendees == true {
                        Text("저장 시 캘린더 서비스가 참석자에게 변경 알림을 보낼 수 있습니다.")
                            .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.8))
                    }
                }.padding(.vertical, 4).disabled(calendar.saving)
            }
            if let message = calendar.saveError ?? validation {
                Text(message).font(.system(size: 11)).foregroundStyle(calendar.saveError == nil ? .white.opacity(0.4) : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("작성 중에는 패널이 자동으로 닫히지 않습니다.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            }
        }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 20)
            .environment(\.calendar, calendar.calendar).environment(\.timeZone, calendar.calendar.timeZone)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { titleFocused = true } }
            .onChange(of: draft.form.allDay) { allDay in
                if !allDay && draft.form.end <= draft.form.start { draft.form.end = draft.form.start.addingTimeInterval(3600) }
            }
    }

    private var validation: String? { draft.form.validation(calendar: calendar.calendar, choices: calendar.writableCalendars) }

    private func dateField(_ title: String, date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            DatePicker(title, selection: date, displayedComponents: draft.form.allDay ? [.date] : [.date, .hourAndMinute])
                .datePickerStyle(.stepperField).labelsHidden().accessibilityLabel(title)
        }
    }
}
