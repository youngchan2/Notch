import SwiftUI

enum ClaudeConnectionStep { case location, remote }

struct RemoteConnectionSelection {
    private(set) var original: Set<String>
    var selected: Set<String>
    init(connected: Set<String>) { original = connected; selected = connected }
    var additions: Set<String> { selected.subtracting(original) }
    var removals: Set<String> { original.subtracting(selected) }
    var hasChanges: Bool { selected != original }
    mutating func toggle(_ host: String) {
        if selected.contains(host) { selected.remove(host) } else { selected.insert(host) }
    }
    mutating func rebase(connected: Set<String>) { original = connected }
}

/// Both steps live inside the existing island panel, including manual host entry.
struct ClaudeConnectionView: View {
    @ObservedObject var alerts: AIAlertBridge
    @ObservedObject var usage: UsageBridge
    var body: some View {
        Group {
            if alerts.claudeConnection == .remote {
                RemoteConnectionsView(alerts: alerts)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Claude 연결").font(.system(size: 19, weight: .semibold))
                        Spacer()
                        Button { alerts.closeClaudeConnection() } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.55)).accessibilityLabel("Claude 연결 닫기")
                    }
                    Text("사용량을 확인하고 알림을 받을 위치를 선택하세요.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    location("로컬", detail: "이 Mac의 Claude Code", symbol: "laptopcomputer",
                             action: usage.claudeEnabled ? "이 Mac 보기" : "연결하기") {
                        if !usage.claudeEnabled { usage.chooseClaude(true) }
                        if !alerts.configured.contains(.claude) { alerts.connect(.claude) }
                        usage.selectedClaudeHost = ClaudeUsageAccount.localID
                        alerts.closeClaudeConnection()
                    }
                    location("원격", detail: "SSH 서버의 Claude Code", symbol: "network",
                             action: alerts.remoteStatus.isEmpty ? "서버 선택" : "\(alerts.remoteStatus.count)개 연결됨") {
                        alerts.refreshSSHHosts(); alerts.claudeConnection = .remote
                    }
                    if !alerts.message.isEmpty {
                        Text(alerts.message).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if usage.claudeEnabled {
                        Button("이 Mac 사용량 연결 해제") {
                            usage.chooseClaude(false)
                            alerts.closeClaudeConnection()
                        }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                    Text("로컬과 원격을 함께 연결할 수 있어요.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 20).foregroundStyle(.white)
            .onExitCommand { alerts.closeClaudeConnection() }
    }
    private func location(_ title: String, detail: String, symbol: String, action: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 23, weight: .light)).frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text(action).font(.system(size: 10)).foregroundStyle(Color.accentColor)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }.padding(18).frame(maxWidth: .infinity)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).disabled(alerts.remoteBusy)
            .accessibilityLabel("Claude \(title), \(detail), \(action)")
    }
}

struct RemoteConnectionsView: View {
    @ObservedObject var alerts: AIAlertBridge
    @State private var selection: RemoteConnectionSelection
    @State private var manualHosts: Set<String> = []
    @State private var showsManual = false
    @State private var manualHost = ""
    @State private var manualError = ""
    @FocusState private var manualFocused: Bool
    init(alerts: AIAlertBridge) {
        self.alerts = alerts
        _selection = State(initialValue: RemoteConnectionSelection(connected: Set(alerts.remoteStatus.keys)))
    }
    private var hosts: [String] {
        Set(alerts.sshHosts).union(alerts.remoteStatus.keys).union(manualHosts).union(selection.selected)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Button { alerts.claudeConnection = .location } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).padding(.vertical, 7).padding(.trailing, 5)
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).accessibilityLabel("Claude 연결 위치 선택으로 돌아가기")
                Text("SSH 연결 추가").font(.system(size: 19, weight: .semibold))
                Spacer()
                Button { alerts.closeClaudeConnection() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).padding(8)
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.55)).accessibilityLabel("SSH 연결 선택 닫기")
            }
            ScrollView {
                VStack(spacing: 0) {
                    if hosts.isEmpty {
                        Text("SSH 서버가 없어요. 아래에서 수동으로 추가해 주세요.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(24)
                    }
                    ForEach(hosts, id: \.self) { host in
                        Button { selection.toggle(host) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer").font(.system(size: 17, weight: .regular)).frame(width: 22)
                                Text(host).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 6)
                                if let status = alerts.remoteStatus[host] {
                                    Text(status).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                                }
                                Image(systemName: selection.selected.contains(host) ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 17)).foregroundStyle(selection.selected.contains(host) ? Color.accentColor : .white.opacity(0.25))
                            }.padding(.horizontal, 16).frame(height: 42).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(alerts.remoteBusy)
                            .accessibilityLabel(host + " SSH 선택").accessibilityValue(selection.selected.contains(host) ? "선택됨" : "선택 안 됨")
                            .accessibilityAddTraits(selection.selected.contains(host) ? .isSelected : [])
                        if host != hosts.last { Divider().overlay(.white.opacity(0.035)).padding(.leading, 50).padding(.trailing, 16) }
                    }
                }
            }.background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))
                .clipShape(RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.09), lineWidth: 1))
            if showsManual {
                HStack(spacing: 8) {
                    TextField("SSH 서버 이름", text: $manualHost).textFieldStyle(.plain).font(.system(size: 12))
                        .padding(9).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        .focused($manualFocused).onSubmit(addManualHost)
                    Button("목록에 추가", action: addManualHost).font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }.disabled(alerts.remoteBusy)
            }
            if !manualError.isEmpty || !alerts.message.isEmpty || !alerts.sshReadWarning.isEmpty {
                Text(!manualError.isEmpty ? manualError : (!alerts.message.isEmpty ? alerts.message : alerts.sshReadWarning))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            HStack(spacing: 16) {
                Button { alerts.refreshSSHHosts() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14)).padding(5)
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).accessibilityLabel("SSH 설정 새로고침").disabled(alerts.remoteBusy)
                Button {
                    showsManual.toggle(); manualError = ""
                    alerts.claudeManualEntry = showsManual; manualFocused = showsManual
                } label: { Text("수동으로 추가").font(.system(size: 12)) }
                    .buttonStyle(.plain).disabled(alerts.remoteBusy)
                Spacer()
                if alerts.remoteBusy { ProgressView().controlSize(.small) }
                Button {
                    manualFocused = false
                    alerts.applyRemoteChanges(additions: selection.additions, removals: selection.removals)
                } label: {
                    Text(selection.removals.isEmpty ? "추가" : "적용").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 23).padding(.vertical, 10)
                        .foregroundStyle(selection.hasChanges ? Color.white : .white.opacity(0.3))
                        .background(selection.hasChanges ? Color.accentColor.opacity(0.7) : .white.opacity(0.1), in: Capsule())
                }.buttonStyle(.plain).disabled(!selection.hasChanges || alerts.remoteBusy)
                    .accessibilityLabel(selection.removals.isEmpty ? "선택한 SSH 서버 추가" : "SSH 연결 변경 적용")
            }
        }.onChange(of: alerts.remoteBusy) { busy in
            if !busy { selection.rebase(connected: Set(alerts.remoteStatus.keys)) }
        }.onDisappear { alerts.claudeManualEntry = false }
    }
    private func addManualHost() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteClaude.validHost(host) else { manualError = "평소 SSH 접속에 쓰는 서버 이름을 입력해 주세요."; return }
        manualHosts.insert(host); selection.selected.insert(host)
        manualHost = ""; manualError = ""; showsManual = false; manualFocused = false
        alerts.claudeManualEntry = false
    }
}
