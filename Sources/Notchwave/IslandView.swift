import AppKit
import SwiftUI

private let mint = Color(red: 0.38, green: 0.91, blue: 0.65)

/// ImageRenderer cannot draw the AppKit-backed scrolling surface.
struct PreviewSafeScroll<Content: View>: View {
    let snapshot: Bool
    let content: Content
    init(snapshot: Bool, @ViewBuilder content: () -> Content) {
        self.snapshot = snapshot
        self.content = content()
    }
    var body: some View {
        if snapshot {
            GeometryReader { geometry in
                content.frame(width: geometry.size.width)
                    .fixedSize(horizontal: false, vertical: true)
            }.clipped()
        } else {
            ScrollView(showsIndicators: false) { content }
        }
    }
}

/// Concave shoulders meet the top edge; the lower corners remain rounded.
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let shoulder: CGFloat = 9
        let r = min(radius, rect.height / 2)
        let w = rect.width, h = rect.height
        return Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: w, y: 0))
            p.addQuadCurve(to: CGPoint(x: w - shoulder, y: shoulder), control: CGPoint(x: w - shoulder, y: 0))
            p.addLine(to: CGPoint(x: w - shoulder, y: h - r))
            p.addQuadCurve(to: CGPoint(x: w - shoulder - r, y: h), control: CGPoint(x: w - shoulder, y: h))
            p.addLine(to: CGPoint(x: shoulder + r, y: h))
            p.addQuadCurve(to: CGPoint(x: shoulder, y: h - r), control: CGPoint(x: shoulder, y: h))
            p.addLine(to: CGPoint(x: shoulder, y: shoulder))
            p.addQuadCurve(to: .zero, control: CGPoint(x: shoulder, y: 0))
            p.closeSubpath()
        }
    }
}

/// Fixed, equal wings keep the physical cutout centered even with long labels.
struct NotchAlertLayout<Leading: View, Trailing: View, Detail: View>: View {
    let geometry: IslandGeometry
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading().padding(.horizontal, 8).frame(width: geometry.alertWingWidth)
                Color.clear.frame(width: geometry.notchWidth)
                trailing().padding(.horizontal, 8).frame(width: geometry.alertWingWidth).offset(x: -3)
            }.frame(height: geometry.topHeight)
            detail().padding(.horizontal, 20).frame(height: geometry.notchAlertDetailHeight)
        }.frame(width: geometry.alertWidth, height: geometry.notchAlertHeight)
    }
}

struct DemoArtwork: View {
    var body: some View {
        GeometryReader { proxy in
            let s = proxy.size.width
            ZStack {
                LinearGradient(colors: [Color(red: 0.55, green: 0.17, blue: 0.12), Color(red: 0.95, green: 0.53, blue: 0.29), Color(red: 0.19, green: 0.25, blue: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Color(red: 1, green: 0.79, blue: 0.48)).frame(width: s * 0.47).offset(x: s * 0.1, y: -s * 0.1).blur(radius: s * 0.025)
                Ellipse().fill(Color(red: 0.11, green: 0.21, blue: 0.23)).frame(width: s * 1.5, height: s * 0.65).rotationEffect(.degrees(-20)).offset(x: -s * 0.18, y: s * 0.4)
                Ellipse().fill(Color(red: 0.05, green: 0.13, blue: 0.16)).frame(width: s * 1.7, height: s * 0.6).rotationEffect(.degrees(17)).offset(x: s * 0.26, y: s * 0.5)
            }.frame(width: s, height: proxy.size.height).clipped()
        }
        .accessibilityHidden(true)
    }
}

struct Cover: View {
    @ObservedObject var player: SpotifyBridge
    var size: CGFloat
    var body: some View {
        ZStack {
            if player.demo { DemoArtwork() }
            else if let image = player.artwork {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Color.white.opacity(0.085)
                Image(systemName: "music.note").font(.system(size: size * 0.35, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 12 : 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size > 40 ? 12 : 5).stroke(.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityLabel("앨범 커버")
    }
}

struct Equalizer: View {
    var playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !playing || reduceMotion)) { context in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4) { index in
                    Capsule().fill(Color.accentColor.opacity(playing ? 1 : 0.45))
                        .frame(width: 2.5, height: barHeight(index, at: context.date))
                }
            }.frame(width: 22, height: 20)
        }
        .accessibilityLabel(playing ? "재생 중" : "일시정지")
    }

    private func barHeight(_ index: Int, at date: Date) -> CGFloat {
        guard playing, !reduceMotion else { return CGFloat([6, 12, 9, 5][index]) }
        let t = date.timeIntervalSinceReferenceDate
        let frequency = 4.3 + Double(index) * 0.6
        let wave = (sin(t * frequency + Double(index) * 1.7) + 1) / 2
        return CGFloat(5 + wave * 12)
    }
}

struct TransportButton: View {
    var symbol: String
    var label: String
    var primary = false
    var selected: Bool? = nil
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: primary ? 20 : 13, weight: .semibold))
                .foregroundStyle(selected == true ? Color.accentColor : Color.white.opacity(0.9))
                .frame(width: primary ? 34 : 27, height: 30)
                .background(Color.white.opacity(hovered ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottom) {
                    if selected == true { Circle().fill(Color.accentColor).frame(width: 3, height: 3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(selected.map { $0 ? "켬" : "끔" } ?? "")
        .accessibilityAddTraits(selected == true ? .isSelected : [])
    }
}

struct PlaybackProgress: View {
    @ObservedObject var player: SpotifyBridge
    var track: Track
    @State private var scrubbing: Double?
    @State private var hovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let seconds = scrubbing ?? track.elapsed(at: context.date)
            let fraction = track.duration > 0 ? min(1, max(0, seconds / track.duration)) : 0
            VStack(spacing: 5) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16)).frame(height: 3)
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(0, proxy.size.width * fraction), height: 3)
                        if hovered || scrubbing != nil {
                            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                                .offset(x: max(0, min(proxy.size.width - 8, proxy.size.width * fraction - 4)))
                        }
                    }.frame(width: proxy.size.width, height: 12, alignment: .leading).contentShape(Rectangle())
                        .disabled(player.busy || track.duration <= 0)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                scrubbing = min(1, max(0, value.location.x / max(1, proxy.size.width))) * track.duration
                            }
                            .onEnded { _ in
                                if let seconds = scrubbing { player.send(.seek(seconds)) }
                                scrubbing = nil
                            })
                }.frame(height: 12)
                    .onHover { hovered = $0 }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("재생 위치")
                    .accessibilityValue("\(timeLabel(seconds)) / \(timeLabel(track.duration))")
                    .accessibilityAdjustableAction { direction in
                        player.send(.seek(seconds + (direction == .increment ? 5 : -5)))
                    }
                HStack {
                    Text(timeLabel(seconds)).frame(minWidth: 34, alignment: .leading)
                    Spacer(minLength: 4)
                    HStack(spacing: 3) {
                        TransportButton(symbol: "shuffle", label: track.shuffling ? "셔플 끄기" : "셔플 켜기", selected: track.shuffling) { player.send(.shuffle) }
                            .disabled(!track.canShuffle).opacity(track.canShuffle ? 1 : 0.3)
                        TransportButton(symbol: "backward.end.fill", label: "이전 곡") { player.send(.previous) }
                        TransportButton(symbol: track.playing ? "pause.fill" : "play.fill", label: track.playing ? "일시정지" : "재생", primary: true) { player.send(.toggle) }
                        TransportButton(symbol: "forward.end.fill", label: "다음 곡") { player.send(.next) }
                        TransportButton(symbol: "repeat", label: track.repeating ? "반복 재생 끄기" : "반복 재생 켜기", selected: track.repeating) { player.send(.repeatMode) }
                            .disabled(!track.canRepeat).opacity(track.canRepeat ? 1 : 0.3)
                    }.disabled(player.busy)
                    Spacer(minLength: 4)
                    Text(timeLabel(track.duration)).frame(minWidth: 34, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

struct CompactPlayback: View {
    @ObservedObject var player: SpotifyBridge
    let track: Track
    let geometry: IslandGeometry

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Cover(player: player, size: min(geometry.hasNotch ? 18 : 20, geometry.topHeight - 6))
                    .offset(x: geometry.hasNotch ? 3 : 0).frame(width: geometry.compactWingWidth)
                Spacer(minLength: geometry.hasNotch ? geometry.notchWidth : 0)
                Equalizer(playing: track.playing).offset(x: geometry.hasNotch ? -3 : 0).frame(width: geometry.compactWingWidth)
            }.frame(height: geometry.topHeight)
            if geometry.hasNotch { progress.frame(height: 3).padding(.horizontal, 20) }
        }
        .overlay(alignment: .bottom) {
            if !geometry.hasNotch { progress.frame(height: 2).padding(.horizontal, 16).padding(.bottom, 1) }
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(Color.accentColor)
                        .frame(width: proxy.size.width * track.progress(at: context.date))
                }
            }
        }.accessibilityHidden(true)
    }
}

struct IslandView: View {
    @ObservedObject var player: SpotifyBridge
    @ObservedObject var state: IslandState
    @ObservedObject var calendar: CalendarBridge
    @ObservedObject var battery: BatteryBridge
    @ObservedObject var usage: UsageBridge
    @ObservedObject var alerts: AIAlertBridge
    var snapshot = false
    @State private var systemAccent = Color(nsColor: .controlAccentColor)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let geometry = state.geometry
        let active = player.track?.playing == true
        let compactActive = active || alerts.pendingCount > 0
        let hasBanner = battery.alert != nil || alerts.banner != nil
        let emphasized = battery.alert == nil && alerts.banner != nil && alerts.isEmphasized
        let size = geometry.hitRect(expanded: state.expanded, active: compactActive, tab: state.layoutTab,
            alert: hasBanner, chargingAlert: battery.alert?.kind == .charging, aiAlertEmphasized: emphasized).size
        let width = size.width, height = size.height
        VStack(spacing: 0) {
            if state.expanded {
                expandedHeader
                tabBar.frame(height: 38)
                expandedPanelContent
            } else { compactButton(height: height) }
        }
        .frame(width: width, height: height, alignment: .top)
        .modifier(IslandChrome(hasNotch: geometry.hasNotch, expanded: state.expanded, snapshot: snapshot))
        .overlay {
            if geometry.hasNotch {
                NotchShape(radius: state.expanded ? 27 : 11)
                    .stroke(Color.accentColor.opacity(emphasized ? 0.55 : 0), lineWidth: 1.2)
                    .allowsHitTesting(false)
            } else {
                RoundedRectangle(cornerRadius: state.expanded ? 27 : 18)
                    .strokeBorder(Color.accentColor.opacity(emphasized ? 0.55 : 0), lineWidth: 1.2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: state.expanded ? 27 : 18))
        .overlay(alignment: .trailing) {
            if !state.expanded && !hasBanner && alerts.pendingCount > 0 {
                Text("\(alerts.pendingCount)").font(.system(size: 8, weight: .bold)).foregroundStyle(.black)
                    .frame(minWidth: 13, minHeight: 13).background(Color.accentColor, in: Circle()).padding(.trailing, geometry.hasNotch ? 12 : 3)
                    .allowsHitTesting(false).accessibilityLabel("승인 대기 \(alerts.pendingCount)개")
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.84), value: state.expanded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: active)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: battery.alert?.id)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: alerts.banner?.id)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.8), value: emphasized)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: state.showsAIAlerts)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: state.tab)
        .opacity(state.hidden ? 0 : 1)
        .frame(width: geometry.windowFrame.width, height: geometry.windowFrame.height, alignment: .top)
        .preferredColorScheme(.dark)
        .background {
            SystemAccentReader { color in systemAccent = Color(nsColor: color) }
                .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .accentColor(systemAccent)
        .tint(systemAccent)
        .contextMenu {
            Button("캘린더 보기") { state.showsAIAlerts = false; state.tab = .calendar; state.expanded = true; calendar.refresh() }
            Button("AI 알림 보기") { state.showsAIAlerts = true; state.expanded = true }.disabled(calendar.draft != nil)
            Button("Spotify 연결") { NSApp.sendAction(#selector(AppDelegate.connect), to: NSApp.delegate, from: nil) }
            Button(player.demo ? "미리보기 끝내기" : "디자인 미리보기") { player.setDemo(!player.demo) }
            Button("미리보기 창 열기") { NSApp.sendAction(#selector(AppDelegate.showPreview), to: NSApp.delegate, from: nil) }
            Divider()
            Button("Notchwave 종료") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder private var expandedHeader: some View {
        if battery.alert == nil, let alert = alerts.banner {
            Button { alerts.open(alert) } label: { headerContent.contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityLabel(alert.conversationLabel + ", " + alert.openingAction)
        } else { headerContent }
    }

    @ViewBuilder private var headerContent: some View {
        let geometry = state.geometry
        HStack {
            Text("NOTCHWAVE").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(.white.opacity(0.38))
            Spacer(minLength: geometry.hasNotch ? geometry.notchWidth : 15)
            Circle().fill(isDemo ? Color.orange.opacity(0.8) : mint).frame(width: 4, height: 4)
            if let alert = battery.alert {
                if alert.kind == .charging {
                    Image(systemName: alert.device.symbol).foregroundStyle(alert.device.color)
                    Text("충전 중").font(.system(size: 10)).foregroundStyle(alert.device.color)
                    ChargingRing(device: alert.device, size: 22, snapshot: snapshot).id(alert.id)
                } else {
                    Text(alert.device.name + " \(alert.device.percent ?? 0)%").font(.system(size: 10, weight: .medium)).foregroundStyle(alert.device.color).lineLimit(1)
                }
            } else if let alert = alerts.banner {
                Label(alert.conversationLabel + (alert.kind == .permission ? " · 승인 대기" : " · 완료"), systemImage: alert.symbol)
                    .font(.system(size: 10)).foregroundStyle(Color.accentColor).lineLimit(1)
                    .help(alert.conversationLabel)
            } else {
                Text(isDemo ? "미리보기" : (state.showsAIAlerts ? "AI 알림" : state.tab.rawValue)).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 29)
        .frame(height: geometry.topHeight)
        .transition(.opacity)
    }

    @ViewBuilder private var expandedPanelContent: some View {
        let geometry = state.geometry
        let expandedSize = geometry.expandedSize(for: state.layoutTab)
        Group {
            if state.showsAIAlerts {
                AIAlertsView(alerts: alerts, snapshot: snapshot)
                    .frame(width: expandedSize.width, height: geometry.utilityContentHeight)
            } else if state.tab == .calendar {
                CalendarWeekView(calendar: calendar, snapshot: snapshot)
                    .frame(width: expandedSize.width, height: geometry.calendarContentHeight)
            } else if state.tab == .battery {
                BatteryView(battery: battery, snapshot: snapshot).frame(width: expandedSize.width, height: geometry.utilityContentHeight)
            } else if state.tab == .usage {
                UsageView(usage: usage, alerts: alerts, snapshot: snapshot).frame(width: expandedSize.width, height: geometry.utilityContentHeight)
            } else {
                expandedContent.frame(width: expandedSize.width, height: 160, alignment: .top)
            }
        }.transition(.opacity)
    }

    @ViewBuilder private func compactButton(height: CGFloat) -> some View {
        let geometry = state.geometry
        let active = player.track?.playing == true
        Button {
            if battery.alert == nil, let alert = alerts.banner { alerts.open(alert); return }
            state.holdOpenUntil = Date().addingTimeInterval(6)
            state.expanded = true
            if battery.alert != nil { state.showsAIAlerts = false; state.tab = .battery; battery.dismissAlert() }
            else if alerts.pendingCount > 0 { state.showsAIAlerts = true }
        } label: {
            Group {
                if let alert = battery.alert {
                    if alert.kind == .charging {
                        CompactChargingAlert(device: alert.device, geometry: geometry, snapshot: snapshot).id(alert.id)
                    } else { compactAlert(alert.device, geometry: geometry) }
                } else if let alert = alerts.banner {
                    CompactAIAlert(event: alert, geometry: geometry, emphasized: alerts.isEmphasized)
                } else if active, let track = player.track {
                    CompactPlayback(player: player, track: track, geometry: geometry)
                } else {
                    Color.clear.frame(width: geometry.idleWidth)
                }
            }.frame(height: height).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(battery.alert == nil && alerts.banner != nil ? "\(alerts.banner!.provider.title), \(alerts.banner!.conversationLabel), \(alerts.banner!.openingAction)" : (geometry.hasNotch ? "노치 패널 펼치기" : "캡슐 패널 펼치기"))
            .transition(.opacity)
    }

    private var isDemo: Bool {
        if state.showsAIAlerts { return alerts.demo }
        switch state.tab { case .spotify: return player.demo; case .calendar: return calendar.demo; case .battery: return battery.demo; case .usage: return usage.demo }
    }

    @ViewBuilder private func compactAlert(_ device: DeviceBattery, geometry: IslandGeometry) -> some View {
        if geometry.hasNotch {
            NotchAlertLayout(geometry: geometry) {
                Image(systemName: device.symbol).font(.system(size: 15)).foregroundStyle(device.color)
            } trailing: {
                Text("\(device.percent ?? 0)%").font(.system(size: 11, weight: .semibold)).foregroundStyle(device.color)
            } detail: {
                HStack(spacing: 6) {
                    Text(device.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("배터리 부족").font(.system(size: 9)).foregroundStyle(device.color).fixedSize()
                }
            }.foregroundStyle(.white)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("배터리 부족, \(device.name), \(device.percent ?? 0)퍼센트")
        } else {
            HStack(spacing: 8) {
                Image(systemName: device.symbol).font(.system(size: 16)).foregroundStyle(device.color)
                Text(device.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(device.percent ?? 0)%").font(.system(size: 11, weight: .semibold)).foregroundStyle(device.color)
                BatteryGlyph(device: device)
            }.padding(.horizontal, 18).frame(width: geometry.alertWidth).foregroundStyle(.white)
                .accessibilityLabel("배터리 부족, \(device.name), \(device.percent ?? 0)퍼센트")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(IslandTab.allCases, id: \.self) { tab in
                Button {
                    state.showsAIAlerts = false
                    state.tab = tab
                    state.holdOpenUntil = Date().addingTimeInterval(3)
                    if tab == .calendar { calendar.refresh() }
                    if tab == .battery { battery.refresh() }
                    if tab == .usage { usage.refresh() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol).font(.system(size: 11))
                        Text(tab.rawValue).font(.system(size: 11, weight: .medium))
                    }.foregroundStyle(state.tab == tab && !state.showsAIAlerts ? Color.white : Color.white.opacity(0.4))
                        .padding(.horizontal, 12).frame(height: 27)
                        .background(.white.opacity(state.tab == tab && !state.showsAIAlerts ? 0.1 : 0), in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel(tab.rawValue + " 탭")
                    .accessibilityAddTraits(state.tab == tab && !state.showsAIAlerts ? .isSelected : [])
            }
            Spacer()
            Button {
                state.showsAIAlerts.toggle()
                state.holdOpenUntil = Date().addingTimeInterval(6)
                alerts.refreshConfiguration()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: alerts.items.isEmpty ? "bell" : "bell.badge")
                        .font(.system(size: 14))
                    if !alerts.items.isEmpty {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                }
                .foregroundStyle(alerts.items.isEmpty ? Color.white.opacity(0.45) : Color.accentColor)
                .frame(width: 36, height: 27).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("AI 알림 보기")
                .accessibilityValue(alerts.items.isEmpty ? "보관된 알림 없음" : "보관된 알림 \(alerts.items.count)개")
                .help(alerts.items.isEmpty ? "AI 알림 보관함" : "보관된 AI 알림 \(alerts.items.count)개")
                .disabled(calendar.draft != nil)
            Button { state.pinned.toggle() } label: {
                Image(systemName: state.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11)).foregroundStyle(state.pinned ? mint : .white.opacity(0.35))
                    .frame(width: 27, height: 27).contentShape(Rectangle())
            }.buttonStyle(.plain).help(state.pinned ? "고정 해제 · 밖을 클릭해도 닫을 수 있습니다" : "마우스를 옮겨도 패널 열어두기")
                .accessibilityLabel(state.pinned ? "패널 고정 해제" : "패널 고정")
        }.padding(.horizontal, 25).padding(.bottom, 5)
    }

    @ViewBuilder private var expandedContent: some View {
        if let track = player.track {
            VStack(spacing: 7) {
                HStack(alignment: .top, spacing: 18) {
                    Button { player.openSpotify() } label: { Cover(player: player, size: 108) }
                        .buttonStyle(.plain).help("Spotify 열기")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        Text(track.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 4)
                        PlaybackProgress(player: player, track: track).id(track.id)
                    }.frame(height: 108)
                }
                if let error = player.commandError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                }
            }.padding(.horizontal, 24).padding(.top, 14)
        } else {
            VStack(spacing: 9) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 26, weight: .light)).foregroundStyle(mint)
                        .frame(width: 48, height: 48).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(player.connection.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        Text(player.connection.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Button(player.connection == .closed ? "Spotify 열기" : (player.connection == .denied ? "설정 열기" : "Spotify 연결")) {
                        if player.connection == .closed { player.openSpotify() }
                        else if player.connection == .denied { player.openPermissionSettings() }
                        else { player.connect() }
                    }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 15).padding(.vertical, 8).foregroundStyle(.black)
                        .background(mint, in: Capsule())
                    Spacer()
                }.padding(.top, 3)
            }.padding(.horizontal, 30).padding(.top, 16)
        }
    }
}

struct IslandChrome: ViewModifier {
    let hasNotch: Bool
    let expanded: Bool
    let snapshot: Bool
    func body(content: Content) -> some View {
        let radius: CGFloat = expanded ? 27 : 18
        if hasNotch {
            content.background(NotchShape(radius: expanded ? 27 : 11).fill(.black).shadow(color: .black.opacity(expanded ? 0.3 : 0), radius: 12, y: 7))
        } else if snapshot {
            // ImageRenderer cannot capture native glass; keep the surface transparent.
            content.overlay { glassRim(radius: radius) }
        } else if #available(macOS 26.0, *) {
            content
                .background { IslandGlassBackdrop().clipShape(RoundedRectangle(cornerRadius: radius)) }
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: radius))
                .overlay { glassRim(radius: radius) }
        } else {
            content
                .background { IslandGlassBackdrop().clipShape(RoundedRectangle(cornerRadius: radius)) }
                .overlay { glassRim(radius: radius) }
        }
    }
    private func glassRim(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius).strokeBorder(
            LinearGradient(colors: [.white.opacity(0.48), .white.opacity(0.08), .white.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 0.65).allowsHitTesting(false)
    }
}

/// Keep the backdrop legible when a nonactivating panel becomes key for text entry.
/// Clear Liquid Glass on its own changes its opacity with the window's active state.
struct IslandGlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
