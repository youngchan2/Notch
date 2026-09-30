import AppKit
import SwiftUI

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var artworkURL: String
    var duration: Double
    var position: Double
    var playing: Bool
    var sampledAt = Date()
    var shuffling = false
    var repeating = false
    var canShuffle = true
    var canRepeat = true

    func elapsed(at date: Date = Date()) -> Double {
        min(max(0, position + (playing ? date.timeIntervalSince(sampledAt) : 0)), max(0, duration))
    }

    func progress(at date: Date = Date()) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, elapsed(at: date) / duration))
    }

    static let demo = Track(id: "demo", title: "A little closer", artist: "Notchwave · 디자인 미리보기",
                            album: "After hours", artworkURL: "", duration: 234, position: 83, playing: true)

    static func decode(_ result: NSAppleEventDescriptor, at date: Date = Date()) -> Track? {
        guard result.numberOfItems == 8 || result.numberOfItems == 12,
              let id = result.atIndex(1)?.stringValue, !id.isEmpty,
              let title = result.atIndex(2)?.stringValue,
              let artist = result.atIndex(3)?.stringValue,
              let album = result.atIndex(4)?.stringValue,
              let art = result.atIndex(5)?.stringValue,
              let ms = result.atIndex(6)?.doubleValue, ms.isFinite, ms >= 0,
              let position = result.atIndex(7)?.doubleValue, position.isFinite,
              let state = result.atIndex(8)?.stringValue else { return nil }
        return Track(id: id, title: title, artist: artist, album: album, artworkURL: art,
                     duration: ms / 1000, position: max(0, position), playing: state == "playing", sampledAt: date,
                     shuffling: result.atIndex(9)?.booleanValue ?? false,
                     repeating: result.atIndex(10)?.booleanValue ?? false,
                     canShuffle: result.atIndex(11)?.booleanValue ?? true,
                     canRepeat: result.atIndex(12)?.booleanValue ?? true)
    }
}

enum Connection: Equatable {
    case ready, needsPermission, denied, closed, idle, unavailable

    var title: String {
        switch self {
        case .ready, .idle: return "음악을 기다리고 있어요"
        case .needsPermission: return "Spotify와 연결해 주세요"
        case .denied: return "Spotify 제어를 허용해 주세요"
        case .closed: return "Spotify를 열어 주세요"
        case .unavailable: return "Spotify에 연결할 수 없어요"
        }
    }

    var detail: String {
        switch self {
        case .ready, .idle: return "노래를 재생하면 이곳에 나타납니다."
        case .needsPermission: return "곡 정보와 재생 버튼을 연결합니다."
        case .denied: return "시스템 설정 → 개인정보 보호 및 보안 → 자동화"
        case .closed: return "Mac용 Spotify 앱에서 음악을 재생해 주세요."
        case .unavailable: return "잠시 후 다시 연결해 주세요."
        }
    }
}

enum IslandTab: String, CaseIterable {
    case spotify = "Spotify"
    case calendar = "캘린더"
    case battery = "배터리"
    case usage = "AI 사용량"
    var symbol: String {
        switch self { case .spotify: return "waveform"; case .calendar: return "calendar"; case .battery: return "battery.100percent"; case .usage: return "chart.bar.xaxis" }
    }
}

struct IslandGeometry {
    var centerX: CGFloat
    var topY: CGFloat
    var notchWidth: CGFloat
    var topHeight: CGFloat
    var hasNotch = true
    var expandedWidth: CGFloat = 520
    var calendarWidth: CGFloat = 760
    var calendarContentHeight: CGFloat = 468
    var utilityContentHeight: CGFloat = 400
    var expandedHeight: CGFloat { topHeight + 38 + 160 }
    var idleWidth: CGFloat { hasNotch ? notchWidth : 112 }
    var compactWidth: CGFloat { hasNotch ? notchWidth + 88 : 112 }
    // The progress line must sit below the physical camera cutout.
    var compactHeight: CGFloat { topHeight + (hasNotch ? 3 : 0) }
    var alertWidth: CGFloat { hasNotch ? max(notchWidth + 250, 430) : 330 }
    func expandedSize(for tab: IslandTab) -> CGSize {
        let content = tab == .calendar ? calendarContentHeight : (tab == .spotify ? 160 : utilityContentHeight)
        return CGSize(width: tab == .calendar ? calendarWidth : expandedWidth, height: topHeight + 38 + content)
    }
    var windowFrame: NSRect {
        let size = expandedSize(for: .calendar)
        return NSRect(x: centerX - (size.width + 48) / 2, y: topY - size.height - 32,
                      width: size.width + 48, height: size.height + 32)
    }
    init(centerX: CGFloat = 0, topY: CGFloat = 0, notchWidth: CGFloat = 184, topHeight: CGFloat = 32, hasNotch: Bool = true) {
        self.centerX = centerX; self.topY = topY; self.notchWidth = notchWidth; self.topHeight = topHeight; self.hasNotch = hasNotch
    }
    init(screen: NSScreen) {
        hasNotch = screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil
        topHeight = hasNotch ? max(32, screen.safeAreaInsets.top) : 24
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(100, right.minX - left.maxX)
            centerX = (left.maxX + right.minX) / 2
            topY = screen.frame.maxY
        } else {
            let visibleMenuHeight = screen.frame.maxY - screen.visibleFrame.maxY
            let menuHeight = visibleMenuHeight > 0 && visibleMenuHeight <= 64 ? visibleMenuHeight : NSStatusBar.system.thickness
            let placement = Self.menuBarCapsule(screenFrame: screen.frame, menuBarHeight: menuHeight)
            notchWidth = placement.width; centerX = placement.midX
            topY = placement.maxY; topHeight = placement.height
        }
        expandedWidth = min(max(520, notchWidth + 180), screen.frame.width - 40)
        calendarWidth = min(max(760, expandedWidth), screen.frame.width - 40)
        calendarContentHeight = min(468, max(300, topY - screen.visibleFrame.minY - topHeight - 90))
        utilityContentHeight = min(400, calendarContentHeight)
    }
    static func menuBarCapsule(screenFrame: NSRect, menuBarHeight: CGFloat) -> NSRect {
        // Stay in the menu bar even when it is automatically hidden. visibleFrame
        // describes the usable desktop, not the position of a menu-bar overlay.
        let barHeight = max(22, menuBarHeight)
        return NSRect(x: screenFrame.midX - 56, y: screenFrame.maxY - barHeight + 2,
                      width: 112, height: barHeight - 4)
    }
    static func preferredScreen() -> NSScreen? {
        // CGMainDisplayID follows the display arrangement, unlike NSScreen.main (focused window).
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }
            ?? NSScreen.screens.first
    }
    func hitRect(expanded: Bool, active: Bool, tab: IslandTab = .spotify, alert: Bool = false, chargingAlert: Bool = false, aiAlertEmphasized: Bool = false) -> NSRect {
        let size = expandedSize(for: tab)
        let width = expanded ? size.width : (alert ? alertWidth + (aiAlertEmphasized ? 24 : 0) : (active ? compactWidth : idleWidth))
        let height = expanded ? size.height : ((chargingAlert || aiAlertEmphasized) ? max(56, topHeight) : (active && !alert ? compactHeight : topHeight))
        return NSRect(x: centerX - width / 2, y: topY - height, width: width, height: height)
    }
    var activationRect: NSRect {
        if !hasNotch { return hitRect(expanded: false, active: true).insetBy(dx: -8, dy: -6) }
        return NSRect(x: centerX - compactWidth / 2, y: topY - topHeight - 16, width: compactWidth, height: topHeight + 16)
    }
}

struct PanelHover {
    enum Action { case none, open, close }
    private var enteredAt: Date?
    private var lastInside = Date.distantPast

    mutating func reset() {
        enteredAt = nil
        lastInside = .distantPast
    }

    mutating func update(inside: Bool, expanded: Bool, pinned: Bool,
                         holdOpenUntil: Date, now: Date) -> Action {
        if inside {
            lastInside = now
            if enteredAt == nil { enteredAt = now }
            return !expanded && now.timeIntervalSince(enteredAt!) >= 0.12 ? .open : .none
        }
        enteredAt = nil
        return expanded && !pinned && now >= holdOpenUntil && now.timeIntervalSince(lastInside) >= 0.45 ? .close : .none
    }
}

@MainActor final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var hidden = false
    @Published var tab: IslandTab = .spotify
    @Published var pinned = false
    @Published var showsAIAlerts = false
    var layoutTab: IslandTab { showsAIAlerts ? .usage : tab }
    @Published var geometry = IslandGeometry()
    var holdOpenUntil = Date.distantPast
    init(expanded: Bool = false, tab: IslandTab = .spotify) {
        self.expanded = expanded
        self.tab = tab
    }

    func dismiss() {
        expanded = false
        pinned = false
        holdOpenUntil = .distantPast
    }
}

func timeLabel(_ value: Double) -> String {
    let seconds = Int(max(0, value.isFinite ? value : 0))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
