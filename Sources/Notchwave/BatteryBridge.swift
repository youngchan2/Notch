import AppKit
import SwiftUI
import IOKit.ps
import Darwin

enum EarbudSide: String {
    case left, right
    var label: String { self == .left ? "왼쪽" : "오른쪽" }
    var badgeSymbol: String { self == .left ? "l.circle.fill" : "r.circle.fill" }
    var sortOrder: Int { self == .left ? 0 : 1 }
}

struct DeviceBattery: Identifiable, Equatable {
    let id: String
    let name: String
    let percent: Int?
    let charging: Bool
    let internalBattery: Bool
    let category: String
    var detail = ""
    var side: EarbudSide?
    var accessibleName: String { side.map { "\(name) \($0.label)" } ?? name }
    var critical: Bool { (percent ?? 101) <= 20 }
    var color: Color {
        if critical { return .red }
        if let percent, percent <= 50 { return .yellow }
        return Color(red: 0.38, green: 0.91, blue: 0.65)
    }
    var symbol: String {
        let name = name.lowercased(), category = category.lowercased()
        if internalBattery { return "laptopcomputer" }
        if category.contains("case") || name.contains("케이스") { return name.contains("airpods") ? "airpodspro.chargingcase.wireless.fill" : "case.fill" }
        if name.contains("airpods pro") { return side.map { "airpodpro.\($0.rawValue)" } ?? "airpodspro" }
        if name.contains("airpods") { return side.map { "airpod.\($0.rawValue)" } ?? "airpods" }
        if category.contains("trackpad") || name.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if category.contains("keyboard") || name.contains("keys") { return "keyboard.fill" }
        if category.contains("mouse") || name.contains("mouse") { return "computermouse.fill" }
        return "headphones"
    }
    static func parse(_ raw: [String: Any], computerName: String) -> DeviceBattery? {
        if let present = raw["Is Present"] as? Bool, !present { return nil }
        let isInternal = (raw["Type"] as? String) == "InternalBattery"
        guard let rawName = raw["Name"] as? String else { return nil }
        let part = raw["Part Identifier"] as? String ?? ""
        let baseID = (raw["Accessory Identifier"] as? String) ?? (raw["Group Identifier"] as? String) ?? rawName
        let id = isInternal ? "internal" : baseID + ":" + part
        let value = (raw["Current Capacity"] as? NSNumber)?.doubleValue
        let maxValue = (raw["Max Capacity"] as? NSNumber)?.doubleValue ?? 100
        let percent: Int? = value.flatMap { v in
            guard v.isFinite, maxValue.isFinite, maxValue > 0, v >= 0, v <= maxValue else { return nil }
            return Int((v / maxValue * 100).rounded())
        }
        let parts = raw["Combined Parts"] as? [[String: Any]] ?? []
        let detail = parts.compactMap { p -> String? in
            guard let side = p["Part Identifier"] as? String, let n = p["Current Capacity"] as? Int, (0...100).contains(n) else { return nil }
            return (side == "Left" ? "왼쪽" : side == "Right" ? "오른쪽" : side) + " \(n)%"
        }.joined(separator: " · ")
        return DeviceBattery(id: id, name: isInternal ? computerName : rawName, percent: percent,
                             charging: (raw["Is Charging"] as? Bool ?? false) || parts.contains { $0["Is Charging"] as? Bool == true },
                             internalBattery: isInternal, category: raw["Accessory Category"] as? String ?? "", detail: detail,
                             side: isInternal ? nil : EarbudSide(rawValue: part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
    }
}

struct BatteryAlert: Identifiable, Equatable {
    enum Kind { case low, charging }
    let id = UUID()
    let device: DeviceBattery
    var kind: Kind = .low
}

struct ChargingAlertPolicy {
    private var previous: [String: Bool]?
    mutating func update(_ devices: [DeviceBattery]) -> [DeviceBattery] {
        let next = Dictionary(devices.map { ($0.id, $0.charging) }, uniquingKeysWith: { _, last in last })
        defer { previous = next }
        // Opening the app with already charging devices should not create a burst of alerts.
        guard let previous else { return [] }
        return devices.filter { $0.charging && previous[$0.id] != true }
    }
}

struct BatteryAlertPolicy {
    // Re-arm only after recovering above 55%, avoiding repeated alerts around 50%.
    var announced: Set<String> = []
    mutating func update(_ devices: [DeviceBattery]) -> [DeviceBattery] {
        var alerts: [DeviceBattery] = []
        for device in devices {
            guard let percent = device.percent else { continue }
            if percent > 55 { announced.remove(device.id) }
            if percent <= 50 && !device.charging && !announced.contains(device.id) {
                announced.insert(device.id); alerts.append(device)
            }
        }
        return alerts
    }
}

enum BatteryReader {
    // Optional macOS compatibility adapter. Apple's open-source IOKit header specifies
    // type 0 as all sources, including accessories. Public API remains the fallback.
    // No battery values or system settings are written.
    private typealias CopyAll = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private static let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    static func read() -> (devices: [DeviceBattery], accessoriesAvailable: Bool) {
        let symbol = library.flatMap { dlsym($0, "IOPSCopyPowerSourcesByType") }
        let copy = symbol.map { unsafeBitCast($0, to: CopyAll.self) }
        let snapshot = copy?(0)?.takeRetainedValue() ?? IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        guard let snapshot, let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return ([], false) }
        let name = Host.current().localizedName ?? "MacBook"
        let devices = list.compactMap { source -> DeviceBattery? in
            guard let raw = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { return nil }
            return DeviceBattery.parse(raw, computerName: name)
        }
        var seen = Set<String>()
        return (devices.filter { seen.insert($0.id).inserted }.sorted {
            if $0.internalBattery != $1.internalBattery { return $0.internalBattery }
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let leftOrder = $0.side?.sortOrder ?? 2, rightOrder = $1.side?.sortOrder ?? 2
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }, copy != nil)
    }
}

@MainActor final class BatteryBridge: ObservableObject {
    @Published private(set) var devices: [DeviceBattery] = []
    @Published private(set) var alert: BatteryAlert?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var accessoriesAvailable = true
    let demo: Bool
    private var timer: Timer?
    private var pending: [BatteryAlert] = []
    private var alertEnd: DispatchWorkItem?
    private var policy = BatteryAlertPolicy()
    private var chargingPolicy = ChargingAlertPolicy()
    init(demo: Bool = false) {
        self.demo = demo
        if demo { devices = Self.samples; updatedAt = Date() }
        else { policy.announced = Set(UserDefaults.standard.stringArray(forKey: "batteryAnnouncedDevices") ?? []) }
    }
    func start() {
        guard !demo, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 0.5
    }
    func stop() { timer?.invalidate(); timer = nil; alertEnd?.cancel(); alert = nil; pending.removeAll(); chargingPolicy = ChargingAlertPolicy() }
    func refresh() {
        guard !demo else { return }
        let sample = BatteryReader.read()
        devices = sample.devices; accessoriesAvailable = sample.accessoriesAvailable; updatedAt = Date()
        let charging = chargingPolicy.update(devices)
        pending.append(contentsOf: charging.map { BatteryAlert(device: $0, kind: .charging) })
        pending.append(contentsOf: policy.update(devices).map { BatteryAlert(device: $0) })
        if let current = alert, !isRelevant(current) { alertEnd?.cancel(); alert = nil }
        UserDefaults.standard.set(Array(policy.announced), forKey: "batteryAnnouncedDevices")
        showNextAlert()
    }
    private func showNextAlert() {
        guard alert == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        guard isRelevant(next) else { showNextAlert(); return }
        let current = devices.first { $0.id == next.device.id } ?? next.device
        alert = BatteryAlert(device: current, kind: next.kind)
        let work = DispatchWorkItem { [weak self] in self?.dismissAlert() }
        alertEnd = work; DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }
    private func isRelevant(_ alert: BatteryAlert) -> Bool {
        devices.contains { device in
            device.id == alert.device.id && (alert.kind == .charging ? device.charging : (!device.charging && (device.percent ?? 101) <= 50))
        }
    }
    func dismissAlert() { alertEnd?.cancel(); alert = nil; showNextAlert() }
    func previewAlert(charging: Bool = false) {
        // Available only in the explicitly-labelled preview window.
        guard demo else { return }
        let device = charging ? DeviceBattery(id: "charging-preview", name: "AirPods Pro", percent: 42, charging: true, internalBattery: false, category: "Headset") : Self.samples[4]
        alert = BatteryAlert(device: device, kind: charging ? .charging : .low)
        let work = DispatchWorkItem { [weak self] in self?.alert = nil }
        alertEnd?.cancel(); alertEnd = work; DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }
    static let samples = [
        DeviceBattery(id: "mac", name: "MacBook Air", percent: 90, charging: false, internalBattery: true, category: ""),
        DeviceBattery(id: "pods", name: "AirPods Pro", percent: 100, charging: true, internalBattery: false, category: "Headset", detail: "왼쪽 100% · 오른쪽 100%"),
        DeviceBattery(id: "case", name: "AirPods Pro 케이스", percent: 75, charging: false, internalBattery: false, category: "Audio Battery Case"),
        DeviceBattery(id: "trackpad", name: "Magic Trackpad", percent: 81, charging: false, internalBattery: false, category: "Trackpad"),
        DeviceBattery(id: "headphones", name: "Bose QC Headphones", percent: 20, charging: false, internalBattery: false, category: "Headphone"),
        DeviceBattery(id: "keyboard", name: "MX Keys Mini", percent: 95, charging: false, internalBattery: false, category: "Keyboard")
    ]
}

struct BatteryDeviceLabel: View {
    let device: DeviceBattery
    var size: CGFloat = 13
    var weight: Font.Weight = .medium
    var body: some View {
        HStack(spacing: 4) {
            Text(device.name).font(.system(size: size, weight: weight)).lineLimit(1)
            if let side = device.side {
                Image(systemName: side.badgeSymbol)
                    .font(.system(size: size * 0.82, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85)).fixedSize()
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(device.accessibleName)
            .help(device.accessibleName)
    }
}

struct ChargingRing: View {
    let device: DeviceBattery
    var size: CGFloat = 40
    var snapshot = false
    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var progress: CGFloat { CGFloat(min(100, max(0, device.percent ?? 0))) / 100 }
    var body: some View {
        ZStack {
            Circle().stroke(device.color.opacity(0.18), lineWidth: size > 30 ? 3 : 2)
            Circle().trim(from: 0, to: filled || snapshot || reduceMotion ? progress : 0)
                .stroke(device.color, style: StrokeStyle(lineWidth: size > 30 ? 3 : 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(device.percent.map(String.init) ?? "—")
                .font(.system(size: size > 30 ? 11 : 7, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(device.color)
        }.frame(width: size, height: size)
            .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9)) { filled = true } }
            .accessibilityLabel(device.percent.map { "배터리 \($0)퍼센트" } ?? "배터리 잔량 확인 중")
    }
}

struct CompactChargingAlert: View {
    let device: DeviceBattery
    let geometry: IslandGeometry
    var snapshot = false
    var body: some View {
        Group {
            if geometry.hasNotch {
                NotchAlertLayout(geometry: geometry) {
                    Image(systemName: device.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(device.color)
                } trailing: {
                    ChargingRing(device: device, size: 24, snapshot: snapshot)
                } detail: {
                    HStack(spacing: 6) {
                        BatteryDeviceLabel(device: device, size: 11, weight: .semibold).foregroundStyle(.white)
                        Spacer(minLength: 4)
                        Label("충전 중", systemImage: "bolt.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(device.color).fixedSize()
                    }
                }
            } else { capsuleContent }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(device.accessibleName), 충전 중, \(device.percent.map { "\($0)퍼센트" } ?? "잔량 확인 중")")
    }

    private var capsuleContent: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol).font(.system(size: 23, weight: .medium)).foregroundStyle(device.color)
            VStack(alignment: .leading, spacing: 3) {
                BatteryDeviceLabel(device: device, size: 10).foregroundStyle(.white)
                Label("충전 중", systemImage: "bolt.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(device.color)
            }.frame(maxWidth: .infinity, alignment: .leading)
            ChargingRing(device: device, snapshot: snapshot)
        }.padding(.horizontal, 18).padding(.vertical, 8)
    }
}

struct BatteryGlyph: View {
    let device: DeviceBattery
    var body: some View {
        HStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.35), lineWidth: 1.5)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 1.5).fill(device.color)
                        .frame(width: max(0, (g.size.width - 5) * CGFloat(device.percent ?? 0) / 100))
                        .padding(2.5)
                }
                if device.charging { Image(systemName: "bolt.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).shadow(color: .black.opacity(0.45), radius: 1) }
            }.frame(width: 27, height: 13)
            Capsule().fill(.white.opacity(0.4)).frame(width: 2, height: 5)
        }.accessibilityHidden(true)
    }
}

struct BatteryView: View {
    @ObservedObject var battery: BatteryBridge
    var snapshot = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("연결된 기기").font(.system(size: 17, weight: .semibold))
                if battery.demo { Text("예시").font(.system(size: 10)).foregroundStyle(.orange) }
                Spacer()
                Button { battery.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).accessibilityLabel("배터리 새로고침")
            }
            if battery.devices.isEmpty {
                Text("표시할 배터리 기기가 없습니다.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PreviewSafeScroll(snapshot: snapshot) {
                    VStack(spacing: 0) {
                        ForEach(battery.devices) { device in
                            HStack(spacing: 13) {
                                Image(systemName: NSImage(systemSymbolName: device.symbol, accessibilityDescription: nil) == nil ? "headphones" : device.symbol)
                                    .font(.system(size: 21, weight: .medium)).frame(width: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    BatteryDeviceLabel(device: device)
                                    if !device.detail.isEmpty { Text(device.detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)) }
                                }
                                Spacer(minLength: 6)
                                Text(device.percent.map { "\($0)%" } ?? "—").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(device.color)
                                BatteryGlyph(device: device)
                            }.frame(minHeight: 44).padding(.vertical, 2)
                                .accessibilityElement(children: .combine)
                            if device.id != battery.devices.last?.id { Divider().overlay(.white.opacity(0.08)).padding(.leading, 45) }
                        }
                    }
                }
            }
            if !battery.accessoriesAvailable || battery.demo {
                HStack {
                    if !battery.accessoriesAvailable {
                        Text("이 macOS에서는 일부 액세서리 잔량을 가져올 수 없습니다.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    if battery.demo { Button("알림 미리보기") { battery.previewAlert() }.font(.system(size: 10)).buttonStyle(.plain) }
                }
            }
        }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 20).foregroundStyle(.white)
    }
}
