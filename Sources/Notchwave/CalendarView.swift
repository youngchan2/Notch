import SwiftUI

private let calendarAccent = Color(red: 0.55, green: 0.70, blue: 1)

struct CalendarWeekView: View {
    @ObservedObject var calendar: CalendarBridge
    var snapshot = false
    private let gutter: CGFloat = 38
    private let hourHeight: CGFloat = 52

    var body: some View {
        Group {
            if let draft = calendar.draft {
                EventEditorView(calendar: calendar, draft: draft)
            } else if calendar.access == .ready {
                VStack(spacing: 0) {
                    toolbar.frame(height: 42)
                    presentationPicker.frame(height: 32)
                    dayHeaders.frame(height: 50)
                    if let day = calendar.selectedDay {
                        dayAgenda(day)

                    } else if calendar.presentation == .summary {
                        summary
                    } else {
                        allDayRow.frame(height: 36)
                        timeline
                    }
                    detailFooter.frame(height: 66)
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 12)
            } else {
                permissionView
            }
        }
        .foregroundStyle(.white)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(rangeLabel).font(.system(size: 16, weight: .semibold))
            if calendar.demo {
                Text("예시 일정").font(.system(size: 9, weight: .medium)).foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 4).background(.orange.opacity(0.12), in: Capsule())
            } else if calendar.loading { ProgressView().controlSize(.mini).scaleEffect(0.7) }
            Spacer(minLength: 6)
            if calendar.demo && !snapshot {
                Button("실제 일정 연결") { calendar.setDemo(false) }
                    .font(.system(size: 10)).foregroundStyle(calendarAccent).buttonStyle(.plain)
            }
            iconButton("plus", "새 일정 만들기") { calendar.beginCreate() }
                .disabled(calendar.writableCalendars.isEmpty)
                .help(calendar.writableCalendars.isEmpty ? "저장 가능한 캘린더가 없습니다" : "새 일정 만들기")
            iconButton("chevron.left", "이전 주") { calendar.movePeriod(-1) }
            Button("오늘") { calendar.today() }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(calendar.isCurrentPeriod ? calendarAccent : .white.opacity(0.75))
                .padding(.horizontal, 11).frame(height: 26)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7)).buttonStyle(.plain)
                .accessibilityLabel("오늘로 이동")
            iconButton("chevron.right", "다음 주") { calendar.movePeriod(1) }
            iconButton("arrow.up.forward.app", "캘린더 앱 열기") { calendar.openCalendar() }
        }
    }

    private var rangeLabel: String {
        let last = calendar.days.last ?? calendar.weekStart
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = calendar.calendar
        formatter.dateFormat = "yyyy년 M월"
        if calendar.calendar.component(.month, from: last) == calendar.calendar.component(.month, from: calendar.weekStart) {
            return formatter.string(from: calendar.weekStart)
        }
        formatter.dateFormat = "M월 d일"
        return formatter.string(from: calendar.weekStart) + " – " + formatter.string(from: last)
    }

    private var presentationPicker: some View {
        HStack(spacing: 3) {
            ForEach(CalendarBridge.Presentation.allCases, id: \.self) { presentation in
                Button { calendar.show(presentation) } label: {
                    Label(presentation.rawValue, systemImage: presentation.symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(calendar.presentation == presentation ? calendarAccent : .white.opacity(0.4))
                        .padding(.horizontal, 10).frame(height: 25)
                        .background(calendar.presentation == presentation ? calendarAccent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).accessibilityLabel(presentation.rawValue + " 보기")
                    .accessibilityAddTraits(calendar.presentation == presentation ? .isSelected : [])
            }
            Spacer()
            Text(calendar.selectedDay != nil ? "같은 날짜를 다시 눌러 \(calendar.presentation.rawValue) 보기" :
                    (calendar.presentation == .timetable ? "스크롤하여 다른 시간 보기" : "날짜를 눌러 하루 전체 보기"))
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
        }
    }

    private var dayHeaders: some View {
        HStack(spacing: calendar.presentation == .summary ? 6 : 0) {
            if calendar.presentation == .timetable {
                Text("주간").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3)).frame(width: gutter)
            }
            ForEach(calendar.days, id: \.self) { day in
                let count = WeekLayout.entries(calendar.events, day: day, calendar: calendar.calendar).count
                let isSelected = calendar.selectedDay.map { calendar.calendar.isDate($0, inSameDayAs: day) } ?? false
                Button { calendar.selectDay(day) } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 5) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "ko_KR"))))
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(dayColor(day))
                            Text("\(calendar.calendar.component(.day, from: day))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(calendar.calendar.isDateInToday(day) ? Color.black : Color.white.opacity(0.85))
                                .frame(width: 23, height: 23)
                                .background(calendar.calendar.isDateInToday(day) ? calendarAccent : .clear, in: Circle())
                        }
                        if calendar.presentation == .summary {
                            Text(count == 0 ? "일정 없음" : "\(count)개 일정")
                                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.35))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                        .background(isSelected ? calendarAccent.opacity(0.08) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)) 일정 보기, \(count)개")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityHint(isSelected ? "다시 누르면 \(calendar.presentation.rawValue)으로 돌아갑니다" : "이 날짜의 전체 일정을 표시합니다")
            }
        }
    }

    private var summary: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            GeometryReader { proxy in
                let nextID = WeekLayout.nextEventID(calendar.events, after: context.date)
                // Reserve room for the overflow button even on short external displays.
                let capacity = max(1, min(3, Int((proxy.size.height - 34) / 68)))
                HStack(alignment: .top, spacing: 6) {
                    ForEach(calendar.days, id: \.self) { day in
                        SummaryDayColumn(calendar: calendar, day: day, capacity: capacity, nextID: nextID)
                    }
                }.frame(width: proxy.size.width, height: proxy.size.height)
            }
        }.padding(.top, 5).padding(.bottom, 8)
    }

    private func dayColor(_ day: Date) -> Color {
        if calendar.calendar.isDateInToday(day) { return calendarAccent }
        return calendar.calendar.isDateInWeekend(day) ? .white.opacity(0.35) : .white.opacity(0.55)
    }

    private var allDayRow: some View {
        HStack(spacing: 0) {
            Text("종일").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3)).frame(width: gutter)
            ForEach(calendar.days, id: \.self) { day in
                let entries = calendar.events.filter { $0.allDay && WeekLayout.overlaps($0, day: day, calendar: calendar.calendar) }
                VStack(spacing: 1) {
                    if let event = entries.first {
                        Button { calendar.select(event) } label: {
                            HStack(spacing: 3) {
                                Text(event.title).lineLimit(1)
                                if entries.count > 1 { Text("+\(entries.count - 1)").fixedSize() }
                            }
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(Color(nsColor: event.color).opacity(0.95))
                            .padding(.horizontal, 5).frame(maxWidth: .infinity).frame(height: 22)
                            .background(Color(nsColor: event.color).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                            .accessibilityLabel("종일, \(event.title). 이 날짜의 전체 일정은 날짜 버튼에서 확인")
                    } else { Color.clear.frame(height: 22) }
                }.padding(.horizontal, 2).frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5) }
    }

    @ViewBuilder private var timeline: some View {
        if snapshot {
            GeometryReader { _ in timelineGrid(hours: 8..<14) }.clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    timelineGrid(hours: 0..<24)
                }
                .onAppear { proxy.scrollTo(8, anchor: .top) }
                .onChange(of: calendar.weekStart) { _ in proxy.scrollTo(8, anchor: .top) }
            }
        }
    }

    private func timelineGrid(hours: Range<Int>) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(hours), id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.28)).frame(width: gutter, height: hourHeight, alignment: .topLeading)
                        .id(hour)
                }
            }
            ForEach(calendar.days, id: \.self) { day in
                DayTimeline(calendar: calendar, day: day, hours: hours, hourHeight: hourHeight)
            }
        }
        .frame(height: CGFloat(hours.count) * hourHeight, alignment: .top)
    }

    private func dayAgenda(_ day: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(day.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "ko_KR"))))
                    .font(.system(size: 12, weight: .medium))
                Text("\(calendar.dayEvents.count)개 일정").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button { calendar.beginCreate(on: day) } label: { Label("일정 추가", systemImage: "plus") }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(calendarAccent)
                    .disabled(calendar.writableCalendars.isEmpty)
            }.padding(.vertical, 8)
            if calendar.dayEvents.isEmpty {
                Text("등록된 일정이 없습니다.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(calendar.dayEvents) { event in
                            Button { calendar.select(event) } label: {
                                HStack(spacing: 10) {
                                    Capsule().fill(Color(nsColor: event.color)).frame(width: 3, height: 28)
                                    Text(event.allDay ? "종일" : event.start.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).frame(width: 72, alignment: .leading)
                                    Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Spacer()
                                    Text(event.calendarName).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                                }.padding(8).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailFooter: some View {
        HStack(spacing: 10) {
            if let event = calendar.selection {
                Capsule().fill(Color(nsColor: event.color)).frame(width: 3, height: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text((calendar.notice.map { $0 + " · " } ?? "") + eventTime(event) + " · " + event.calendarName + (event.location.isEmpty ? "" : " · " + event.location))
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if event.editable {
                    Button { calendar.beginEdit(event) } label: {
                        Label("수정", systemImage: "pencil").font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(calendarAccent.opacity(0.12), in: Capsule())
                    }.buttonStyle(.plain).foregroundStyle(calendarAccent).accessibilityLabel("선택한 일정 수정")
                } else {
                    Text("읽기 전용").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                        .help("구독 캘린더 또는 다른 사람이 초대한 일정은 캘린더 앱에서 확인해 주세요.")
                }
                iconButton("xmark", "일정 상세 닫기") { calendar.clearSelection() }
            } else {
                Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(calendarAccent.opacity(0.8))
                VStack(alignment: .leading, spacing: 5) {
                    Text(calendar.notice ?? "이번 주 \(calendar.periodEvents.count)개 일정")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    Text(calendar.demo ? "가상 일정입니다. 실제 캘린더는 변경되지 않습니다." : "일정을 눌러 상세 보기 · 날짜를 눌러 하루 전체 보기")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                }
                Spacer(minLength: 0)
                if !calendar.demo {
                    iconButton("arrow.clockwise", "일정 새로고침") { calendar.refresh() }
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5) }
    }

    private func eventTime(_ event: CalendarEntry) -> String {
        let start = event.start.formatted(.dateTime.month().day().locale(Locale(identifier: "ko_KR")))
        if event.allDay {
            let last = calendar.calendar.date(byAdding: .day, value: -1, to: event.end) ?? event.start
            return start + (calendar.calendar.isDate(last, inSameDayAs: event.start) ? " · 종일" : " – " + last.formatted(date: .abbreviated, time: .omitted) + " · 종일")
        }
        let end = calendar.calendar.isDate(event.start, inSameDayAs: event.end)
            ? event.end.formatted(date: .omitted, time: .shortened)
            : event.end.formatted(date: .abbreviated, time: .shortened)
        return start + " " + event.start.formatted(date: .omitted, time: .shortened) + " – " + end
    }

    private var permissionView: some View {
        VStack(spacing: 15) {
            Image(systemName: "calendar").font(.system(size: 34, weight: .light)).foregroundStyle(calendarAccent)
                .frame(width: 72, height: 72).background(calendarAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))
            Text(permissionTitle).font(.system(size: 18, weight: .semibold))
            Text(permissionDescription).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center).lineSpacing(5)
            HStack(spacing: 16) {
                Button(calendar.requesting ? "권한 확인 중…" : (calendar.access == .denied ? "시스템 설정 열기" : "캘린더 연결")) {
                    if calendar.access == .denied { calendar.openSettings() }
                    else { calendar.connect() }
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                .padding(.horizontal, 18).padding(.vertical, 10).background(calendarAccent, in: Capsule())
                .disabled(calendar.requesting || calendar.access == .restricted)
                Button("예시 일정 보기") { calendar.setDemo(true) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }.padding(.top, 5)
            Text("새 일정과 수정 내용은 저장 버튼을 누를 때 캘린더에 반영됩니다.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3)).padding(.top, 8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(26)
    }

    private var permissionTitle: String {
        switch calendar.access {
        case .denied: return "캘린더 접근을 허용해 주세요"
        case .restricted: return "이 Mac에서는 캘린더 접근이 제한되어 있어요"
        case .failed: return "캘린더 연결을 다시 시도해 주세요"
        default: return "일정 확인과 편집을 노치에서"
        }
    }
    private var permissionDescription: String {
        switch calendar.access {
        case .denied: return "시스템 설정 → 개인정보 보호 및 보안 → 캘린더에서\nNotchwave의 전체 접근을 허용해 주세요."
        case .restricted: return "기기의 관리 설정을 확인해 주세요.\n예시 일정으로 주간 보기를 미리 볼 수 있습니다."
        default: return "Mac 캘린더에 등록된 계정의 일정을 함께 표시합니다.\n일정을 조회하고 저장하려면 macOS에서 ‘전체 접근’을 허용해야 합니다."
        }
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55)).frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

private struct SummaryDayColumn: View {
    @ObservedObject var calendar: CalendarBridge
    let day: Date
    let capacity: Int
    let nextID: String?

    private var entries: [CalendarEntry] {
        WeekLayout.entries(calendar.events, day: day, calendar: calendar.calendar)
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(entries.prefix(capacity))) { event in
                SummaryEventCard(event: event, day: day, dateCalendar: calendar.calendar,
                                 isNext: event.id == nextID,
                                 selected: calendar.selection?.id == event.id) {
                    calendar.select(event)
                }
            }
            if entries.count > capacity {
                Button { calendar.selectDay(day) } label: {
                    Text("+\(entries.count - capacity)개 더 보기")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(calendarAccent)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(day.formatted(date: .abbreviated, time: .omitted)), +\(entries.count - capacity)개 더 보기")
            }
            if entries.isEmpty {
                Text("—").font(.system(size: 12)).foregroundStyle(.white.opacity(0.2)).padding(.top, 15)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(calendar.calendar.isDateInToday(day) ? calendarAccent.opacity(0.06) : .white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.045), lineWidth: 0.5))
    }
}

private struct SummaryEventCard: View {
    let event: CalendarEntry
    let day: Date
    let dateCalendar: Calendar
    let isNext: Bool
    let selected: Bool
    let action: () -> Void

    private var time: String {
        if event.allDay { return "종일" }
        if event.start < dateCalendar.startOfDay(for: day) { return "전날부터" }
        let parts = dateCalendar.dateComponents([.hour, .minute], from: event.start)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    var body: some View {
        let color = Color(nsColor: event.color)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    Text(time).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(color)
                    Spacer(minLength: 0)
                    if isNext { Text("다음").font(.system(size: 8, weight: .medium)).foregroundStyle(calendarAccent) }
                }
                Text(event.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).padding(.vertical, 8)
            .frame(maxWidth: .infinity).frame(height: 62, alignment: .topLeading)
            .background(color.opacity(selected ? 0.26 : 0.13), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(isNext ? calendarAccent.opacity(0.9) : color.opacity(selected ? 0.75 : 0.16), lineWidth: isNext ? 1 : 0.5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(event.allDay ? "종일" : event.start.formatted(date: .abbreviated, time: .shortened)), \(event.title), \(event.calendarName)\(isNext ? ", 다음 예정 일정" : "")")
    }
}

private struct DayTimeline: View {
    @ObservedObject var calendar: CalendarBridge
    let day: Date
    let hours: Range<Int>
    let hourHeight: CGFloat
    private var offset: Double { Double(hours.lowerBound * 60) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if calendar.calendar.isDateInToday(day) { calendarAccent.opacity(0.035) }
                Path { path in
                    path.move(to: .zero)
                    path.addLine(to: CGPoint(x: 0, y: proxy.size.height))
                    for index in 0...hours.count {
                        let y = CGFloat(index) * hourHeight
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                }.stroke(.white.opacity(0.075), lineWidth: 0.5)
                ForEach(WeekLayout.segments(calendar.events, day: day, calendar: calendar.calendar)) { segment in
                    eventBlock(segment, width: proxy.size.width)
                }
                if calendar.calendar.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let parts = calendar.calendar.dateComponents([.hour, .minute], from: context.date)
                        let minutes = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
                        if minutes >= offset && minutes < Double(hours.upperBound * 60) {
                            Rectangle().fill(calendarAccent).frame(height: 1)
                                .overlay(alignment: .leading) { Circle().fill(calendarAccent).frame(width: 4, height: 4) }
                                .offset(y: CGFloat(minutes - offset) / 60 * hourHeight)
                        }
                    }.allowsHitTesting(false)
                }
            }
        }.frame(maxWidth: .infinity).clipped()
    }

    @ViewBuilder private func eventBlock(_ segment: DaySegment, width: CGFloat) -> some View {
        let start = max(offset, segment.startMinute)
        let end = min(Double(hours.upperBound * 60), segment.displayEnd)
        if end > start {
            let columnWidth = width / CGFloat(segment.laneCount)
            let height = max(1, CGFloat(end - start) / 60 * hourHeight - 2)
            let color = Color(nsColor: segment.event.color)
            Button { calendar.select(segment.event) } label: {
                HStack(alignment: .top, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(segment.event.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            .lineLimit(height > 44 ? 2 : 1).frame(maxWidth: .infinity, alignment: .leading)
                        if height > 38 {
                            Text(segment.event.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 8)).foregroundStyle(color.opacity(0.9)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }.padding(4).frame(width: max(2, columnWidth - 4), height: height)
                    .background(color.opacity(calendar.selection?.id == segment.id ? 0.35 : 0.18), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(calendar.selection?.id == segment.id ? 0.75 : 0.15), lineWidth: 0.5))
                    .clipped().contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(segment.event.title), \(segment.event.start.formatted(date: .abbreviated, time: .shortened)), \(segment.event.calendarName)")
                .offset(x: CGFloat(segment.lane) * columnWidth + 2, y: CGFloat(start - offset) / 60 * hourHeight + 1)
        }
    }
}
