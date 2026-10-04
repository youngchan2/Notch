import AppKit
import SwiftUI
import Combine

final class IslandPanel: NSPanel {
    var allowsKeyInput = false
    override var canBecomeKey: Bool { allowsKeyInput }
    override var canBecomeMain: Bool { false }
    // AppKit normally keeps windows below the menu bar. This overlay belongs in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let player = SpotifyBridge()
    let state = IslandState()
    let calendar = CalendarBridge()
    let battery = BatteryBridge()
    let usage = UsageBridge()
    let alerts = AIAlertBridge()
    private var panel: IslandPanel?
    private var permissionObserver: AnyCancellable?
    private var editingObserver: AnyCancellable?
    private var alertObserver: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var hoverTimer: Timer?
    private var hover = PanelHover()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var previewWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let duplicate = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.notchwave.player")
        if duplicate.count > 1 { NSApp.terminate(nil); return }
        setupMenu()
        setupPanel()
        alertObserver = alerts.$queue.compactMap { $0.banner?.id }.removeDuplicates().sink { [weak self] _ in
            guard let self, !self.state.hidden else { return }
            // Keep a background completion visible without focusing or activating this app.
            self.panel?.orderFrontRegardless()
        }
        permissionObserver = calendar.$requesting.dropFirst().sink { [weak self] requesting in
            guard let self else { return }
            // Leave the compact notch reachable while the system permission dialog is open.
            // Permission completion must not reopen a panel the user has already dismissed.
            if requesting { self.dismissPanel() }
        }
        editingObserver = calendar.$draft.combineLatest(state.$tab, alerts.$claudeManualEntry, state.$showsAIAlerts)
            .map { draft, tab, manualEntry, showsAlerts in
                (draft != nil && tab == .calendar) || (!showsAlerts && tab == .usage && manualEntry)
            }
            .removeDuplicates().sink { [weak self] editing in
                DispatchQueue.main.async { self?.setEditingInput(editing) }
            }
        player.start()
        calendar.start()
        battery.start()
        usage.start()
        alerts.start()
        // On a notchless screen, start as an empty capsule until hovered or clicked.
        if state.geometry.hasNotch { expand() }
        if CommandLine.arguments.contains("--calendar-preview") { calendar.setDemo(true); state.tab = .calendar; state.pinned = true }
        if CommandLine.arguments.contains("--preview-window") { showPreview() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.hoverTimer?.invalidate(); self?.hoverTimer = nil; self?.battery.stop(); self?.usage.stop(); self?.alerts.stop() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenChanged(); self?.startHoverTimer(); self?.player.refresh(); self?.calendar.refresh(); self?.battery.start(); self?.battery.refresh(); self?.usage.start(); self?.usage.refresh(); self?.alerts.start() }
        })
        startHoverTimer()
        installClickMonitors()
        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            showPreview()
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Notchwave 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        for (title, action, key) in [("실행 취소", "undo:", "z"), ("오려두기", "cut:", "x"), ("복사", "copy:", "c"),
                                    ("붙여넣기", "paste:", "v"), ("모두 선택", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Notchwave")
        item.button?.toolTip = "Notchwave · 음악과 캘린더"
        item.button?.setAccessibilityLabel("Notchwave")
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Notchwave", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        for (name, action, key) in [
            ("노치 패널 펼치기", #selector(expand), ""),
            ("캘린더 보기", #selector(showCalendar), ""),
            ("배터리 보기", #selector(showBattery), ""),
            ("AI 사용량 보기", #selector(showUsage), ""),
            ("AI 알림 보기", #selector(showAIAlerts), ""),
            ("Spotify 연결", #selector(connect), ""),
            ("Spotify 열기", #selector(openSpotify), ""),
            ("디자인 미리보기", #selector(toggleDemo), ""),
            ("미리보기 창 열기", #selector(showPreview), ""),
            ("플레이어 숨기기", #selector(toggleHidden), "")
        ] {
            let entry = NSMenuItem(title: name, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Notchwave 종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first(where: { $0.action == #selector(toggleDemo) })?.state = player.demo ? .on : .off
        menu.items.first(where: { $0.action == #selector(toggleHidden) })?.state = state.hidden ? .on : .off
    }

    private func preferredScreen() -> NSScreen? {
        IslandGeometry.preferredScreen()
    }

    private func setupPanel() {
        guard let screen = preferredScreen() else { return }
        state.geometry = IslandGeometry(screen: screen)
        let panel = IslandPanel(contentRect: state.geometry.windowFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Notchwave 플레이어"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: IslandView(player: player, state: state, calendar: calendar, battery: battery, usage: usage, alerts: alerts))
        host.frame = NSRect(origin: .zero, size: state.geometry.windowFrame.size)
        panel.contentView = host
        panel.setFrame(state.geometry.windowFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func startHoverTimer() {
        hoverTimer?.invalidate()
        // Reading cursor position requires no global event tap or Accessibility permission.
        hoverTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHover() }
        }
        hoverTimer?.tolerance = 0.01
        if let hoverTimer { RunLoop.main.add(hoverTimer, forMode: .common) }
    }

    private func checkHover() {
        guard let panel else { return }
        if state.hidden { panel.ignoresMouseEvents = true; return }
        let now = Date()
        alerts.updateMusicVisibility(visible: player.active)
        alerts.bannerPaused = battery.alert != nil
        alerts.refreshPresentation(now: now)
        let pointer = NSEvent.mouseLocation
        let visibleRect = state.geometry.hitRect(expanded: state.expanded, active: player.active || alerts.storedCount > 0, tab: state.layoutTab,
            alert: battery.alert != nil || alerts.banner != nil, chargingAlert: battery.alert?.kind == .charging,
            aiAlertEmphasized: battery.alert == nil && alerts.banner != nil && alerts.isEmphasized)
        let hoverRect = state.expanded ? visibleRect : state.geometry.activationRect.union(visibleRect)
        // The transparent part of the large animation window must never intercept other apps.
        panel.ignoresMouseEvents = !visibleRect.contains(pointer)
        // Keep the arrival card under the pointer long enough to click it, rather than
        // replacing it with tabs during the first fraction of a second of hover.
        if !state.expanded && battery.alert == nil && alerts.banner != nil && alerts.isEmphasized {
            hover.reset(); return
        }
        switch hover.update(inside: hoverRect.contains(pointer), expanded: state.expanded,
                            pinned: state.pinned || (calendar.draft != nil && state.tab == .calendar) || (!state.showsAIAlerts && state.tab == .usage && alerts.claudeConnection != nil), holdOpenUntil: state.holdOpenUntil, now: now) {
        case .open:
            state.expanded = true
            panel.orderFrontRegardless()
            player.refresh()
            if state.tab == .calendar { calendar.refresh() }
            if state.tab == .battery { battery.refresh() }
            if state.tab == .usage { usage.refresh() }
        case .close:
            dismissPanel()
        case .none:
            break
        }
    }

    private func installClickMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // AppKit delivers these handlers on the main thread. Mouse-only monitors do not
        // require Accessibility access and never consume clicks intended for other apps.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.dismissIfOutside(at: NSEvent.mouseLocation)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissIfOutside(at: NSEvent.mouseLocation)
            return event
        }
    }

    private func dismissIfOutside(at point: NSPoint) {
        guard state.expanded, !state.hidden, !(calendar.draft != nil && state.tab == .calendar) else { return }
        let rect = state.geometry.hitRect(expanded: true, active: player.active, tab: state.layoutTab, alert: battery.alert != nil || alerts.banner != nil)
        if !rect.contains(point) { dismissPanel() }
    }

    private func setEditingInput(_ editing: Bool) {
        panel?.allowsKeyInput = editing
        panel?.becomesKeyOnlyIfNeeded = !editing
        if editing {
            expand()
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        } else {
            panel?.resignKey()
            hover.reset()
            state.holdOpenUntil = Date().addingTimeInterval(3)
        }
    }

    private func dismissPanel() {
        panel?.resignKey()
        alerts.closeClaudeConnection()
        state.dismiss()
        hover.reset()
        panel?.ignoresMouseEvents = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        hoverTimer?.invalidate()
        battery.stop(); usage.stop(); alerts.stop()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        permissionObserver?.cancel()
        editingObserver?.cancel()
        alertObserver?.cancel()
    }

    @objc func screenChanged() {
        guard let screen = preferredScreen() else { panel?.orderOut(nil); return }
        state.geometry = IslandGeometry(screen: screen)
        hover.reset()
        panel?.setFrame(state.geometry.windowFrame, display: true)
        if !state.hidden { panel?.orderFrontRegardless() }
    }

    @objc func expand() {
        hover.reset()
        state.hidden = false
        state.expanded = true
        state.holdOpenUntil = Date().addingTimeInterval(6)
        panel?.orderFrontRegardless()
    }
    @objc func connect() { state.showsAIAlerts = false; state.tab = .spotify; player.setDemo(false); player.connect(); expand() }
    @objc func showCalendar() { state.showsAIAlerts = false; state.tab = .calendar; calendar.refresh(); expand() }
    @objc func showBattery() { state.showsAIAlerts = false; state.tab = .battery; battery.refresh(); expand() }
    @objc func showUsage() { state.showsAIAlerts = false; state.tab = .usage; usage.refresh(); expand() }
    @objc func showAIAlerts() { guard calendar.draft == nil else { return }; state.showsAIAlerts = true; alerts.refreshConfiguration(); expand() }
    @objc func openSpotify() { player.openSpotify() }
    @objc func toggleDemo() { player.setDemo(!player.demo); calendar.setDemo(player.demo); expand() }
    @objc func toggleHidden() {
        state.hidden.toggle()
        if state.hidden { dismissPanel(); panel?.orderOut(nil) }
        else { panel?.orderFrontRegardless() }
    }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func showPreview() {
        if let previewWindow { previewWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let demoPlayer = SpotifyBridge()
        demoPlayer.setDemo(true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 738), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Notchwave · 디자인 미리보기"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreviewBoard(player: demoPlayer))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window
    }
}

struct PreviewBoard: View {
    @ObservedObject var player: SpotifyBridge
    @StateObject private var calendar: CalendarBridge
    @StateObject private var state: IslandState
    @StateObject private var battery = BatteryBridge(demo: true)
    @StateObject private var usage = UsageBridge(demo: true)
    @StateObject private var alerts = AIAlertBridge(demo: true)
    var snapshot = false

    @MainActor init(player: SpotifyBridge, snapshot: Bool = false, glass: Bool = false, tab: IslandTab = .battery, compact: Bool = false, alert: String? = nil) {
        self.player = player; self.snapshot = snapshot
        _calendar = StateObject(wrappedValue: CalendarBridge(demo: true))
        let state = IslandState(expanded: !compact, tab: tab)
        state.geometry = IslandGeometry(hasNotch: !glass)
        _state = StateObject(wrappedValue: state)
        if let alert {
            state.expanded = false
            let demoAlerts = AIAlertBridge(demo: true)
            let demoBattery = BatteryBridge(demo: true)
            if alert == "completed" || alert == "permission" {
                demoAlerts.preview(permission: alert == "permission", conversationTitle: "노치 알림 디자인과 긴 대화 제목 표시 개선 작업")
            } else if alert == "music-badge" || alert == "idle-badge" {
                demoAlerts.updateMusicVisibility(visible: true)
                demoAlerts.preview()
                demoAlerts.preview(permission: true)
                demoAlerts.poll(now: Date().addingTimeInterval(6))
                demoAlerts.poll(now: Date().addingTimeInterval(12))
                if alert == "idle-badge" {
                    player.setDemo(false)
                    demoAlerts.updateMusicVisibility(visible: false)
                }
            } else if alert == "low" || alert == "charging" {
                demoBattery.previewAlert(charging: alert == "charging")
            }
            _alerts = StateObject(wrappedValue: demoAlerts)
            _battery = StateObject(wrappedValue: demoBattery)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Notchwave").font(.system(size: 30, weight: .semibold, design: .rounded))
                Spacer()
                Text("YOUR DAY, AT A GLANCE.").font(.system(size: 9, weight: .medium)).tracking(2).foregroundStyle(.white.opacity(0.38))
            }
            Text("음악, 일정, 배터리와 AI 사용량을 한곳에서.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    LinearGradient(colors: [Color(red: 0.34, green: 0.46, blue: 0.52), Color(red: 0.13, green: 0.25, blue: 0.33), Color(red: 0.06, green: 0.12, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Ellipse().fill(.white.opacity(0.04)).frame(width: 1100, height: 400).rotationEffect(.degrees(-18)).offset(x: -200, y: 250)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    HStack {
                        Image(systemName: "apple.logo")
                        Text("Finder").fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "wifi")
                        Text("9:41")
                    }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 20).frame(height: 32)
                    IslandView(player: player, state: state, calendar: calendar, battery: battery, usage: usage, alerts: alerts, snapshot: snapshot)
                }.frame(width: proxy.size.width, height: proxy.size.height, alignment: .top).clipped()
            }.frame(height: 560).clipShape(RoundedRectangle(cornerRadius: 14))
            HStack {
                Text("미리보기의 음악·일정·잔량은 예시입니다.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button(state.geometry.hasNotch ? "Glass로 보기" : "노치로 보기") { state.geometry.hasNotch.toggle() }
                Button(state.expanded ? "접기" : "펼치기") { state.expanded.toggle() }
                Button(player.track?.playing == true ? "음악 끄기" : "음악 켜기") { player.setDemo(player.track?.playing != true) }
                Button("배터리 알림") { state.expanded = false; battery.previewAlert() }
                Button("충전 알림") { state.expanded = false; battery.previewAlert(charging: true) }
            }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.55, green: 0.7, blue: 1))
        }.padding(28).frame(width: 880, height: 738)
            .background(Color(red: 0.048, green: 0.056, blue: 0.062)).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

#if !NOTCHWAVE_CHECKS
@main enum NotchwaveApp {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--notchwave-ai-event"), args.count > index + 1,
           let provider = AIProvider(rawValue: args[index + 1]) { AIHookLink.runHelper(provider: provider); return }
        if args.contains("--link-ai-alerts") {
            do {
                for provider in AIProvider.allCases { try AIHookLink.setEnabled(true, provider: provider); print("Registered \(provider.title) notifications") }
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if let index = args.firstIndex(of: "--link-remote-claude"), args.count > index + 1 {
            do {
                for host in args[index + 1].split(separator: ",").map(String.init) {
                    try RemoteClaude.configure(host: host, enabled: true)
                    print("Registered remote Claude notifications: \(host)")
                }
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if args.contains("--capture-claude-usage") { ClaudeUsageLink.runHelper(); return }
        if args.contains("--self-test") {
            fputs("Run checks from the source folder with: bash scripts/test.sh\n", stderr)
            exit(64)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if let index = args.firstIndex(of: "--render"), args.count > index + 1 {
            renderPreview(to: args[index + 1]); return
        }
        if args.contains("--diagnostics") {
            for screen in NSScreen.screens {
                let g = IslandGeometry(screen: screen)
                print("\(screen.localizedName): frame=\(screen.frame), visible=\(screen.visibleFrame), safeTop=\(screen.safeAreaInsets.top), capsule=\(g.hitRect(expanded: false, active: false)), panel=\(g.windowFrame)")
            }
            let spotifyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
            print("Spotify running: \(spotifyRunning)")
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif

@MainActor func renderPreview(to path: String) {
    let player = SpotifyBridge()
    player.setDemo(true)
    let args = CommandLine.arguments
    let alert = args.firstIndex(of: "--alert-preview").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let renderer = ImageRenderer(content: PreviewBoard(player: player, snapshot: true, glass: args.contains("--glass"), tab: args.contains("--usage") ? .usage : .battery, compact: args.contains("--compact"), alert: alert))
    renderer.scale = 2
    renderer.proposedSize = ProposedViewSize(width: 880, height: 738)
    guard let image = renderer.cgImage else { fatalError("Cannot render preview") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
    do { try data.write(to: URL(fileURLWithPath: path)); print("Preview saved: \(path)") }
    catch { fatalError("\(error)") }
}
