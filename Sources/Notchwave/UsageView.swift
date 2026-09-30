import AppKit
import SwiftUI

struct UsageView: View {
    @ObservedObject var usage: UsageBridge
    @ObservedObject var alerts: AIAlertBridge
    var snapshot = false
    @AppStorage("usageSelectedProvider") private var selectedProvider = "Codex"
    private var provider: String { selectedProvider == "Claude" ? "Claude" : "Codex" }
    private var selectedHost: String {
        usage.claudeLocations.contains(usage.selectedClaudeHost) ? usage.selectedClaudeHost : usage.claudeLocations.first ?? ""
    }
    var body: some View {
        ZStack {
            if alerts.claudeConnection != nil { ClaudeConnectionView(alerts: alerts, usage: usage) }
            else { dashboard }
        }.onDisappear { alerts.closeClaudeConnection() }
            .onChange(of: Set(alerts.remoteStatus.keys)) { _ in usage.refreshClaudeAccounts() }
            .onAppear { usage.refreshClaudeAccounts() }
    }
    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 사용량").font(.system(size: 17, weight: .semibold))
                if usage.demo { Text("예시").font(.system(size: 10)).foregroundStyle(.orange) }
                Spacer()
                Button { usage.refresh(force: true) } label: { Image(systemName: "arrow.clockwise").padding(5) }
                    .buttonStyle(.plain).accessibilityLabel("AI 사용량 새로고침")
            }
            HStack(spacing: 4) {
                providerTab("Codex")
                providerTab("Claude")
            }.padding(3).background(.black.opacity(0.12), in: Capsule())
            if provider == "Claude" { claudeContent }
            else { codexContent }
        }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 20).foregroundStyle(.white)
    }
    private func providerTab(_ title: String) -> some View {
        Button { selectedProvider = title } label: {
            Text(title).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 7)
                .foregroundStyle(provider == title ? .white : .white.opacity(0.5))
                .background(.white.opacity(provider == title ? 0.13 : 0), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(title + " 사용량 탭")
            .accessibilityAddTraits(provider == title ? .isSelected : [])
    }
    @ViewBuilder private var codexContent: some View {
        if !usage.codexEnabled {
            connectionEmpty(symbol: "chart.bar.xaxis", title: "Codex 사용량 연결", detail: "이 Mac에 로그인한 Codex 계정의\n남은 한도와 초기화 시간을 확인하세요.", button: "Codex 연결") {
                usage.chooseCodex(true)
                if !alerts.configured.contains(.codex) { alerts.connect(.codex) }
            }
        } else {
            HStack {
                Label("이 Mac의 Codex 계정", systemImage: "laptopcomputer").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                Spacer()
                if usage.codexLoading { ProgressView().controlSize(.mini) }
            }
            PreviewSafeScroll(snapshot: snapshot) {
                VStack(alignment: .leading, spacing: 12) {
                    if let value = usage.codex {
                        quotaRows(value, used: false)
                    }
                    if !usage.codexMessage.isEmpty {
                        Text(usage.codexMessage).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                notificationButton(.codex)
                Spacer()
                if snapshot {
                    Image(systemName: "ellipsis").padding(6).foregroundStyle(.white.opacity(0.45))
                } else {
                    Menu {
                        Button("사용량 연결 해제") { usage.chooseCodex(false) }
                    } label: { Image(systemName: "ellipsis").padding(6) }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Codex 사용량 연결 관리")
                }
            }
        }
    }
    @ViewBuilder private var claudeContent: some View {
        if usage.claudeLocations.isEmpty {
            connectionEmpty(symbol: "network", title: "Claude 사용량 연결", detail: "이 Mac 또는 SSH 서버를 연결하면\n계정별 사용 한도를 따로 볼 수 있어요.", button: "Claude 연결") {
                alerts.showClaudeConnection()
            }
        } else {
            HStack(spacing: 6) {
                if snapshot {
                    claudeLocationTabs.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) { claudeLocationTabs }
                }
                Button { alerts.showClaudeConnection() } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).padding(7) }
                    .buttonStyle(.plain).accessibilityLabel("Claude 연결 추가 및 관리").disabled(alerts.demo)
            }
            let account = usage.claudeAccounts[selectedHost]
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle").font(.system(size: 12))
                Text(account?.accountLabel ?? "계정 확인 중…").font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    .help(account?.accountLabel ?? "")
                Spacer(minLength: 0)
                if usage.loadingClaudeHosts.contains(selectedHost) { ProgressView().controlSize(.mini) }
            }.foregroundStyle(.white.opacity(0.55)).accessibilityElement(children: .combine)
            PreviewSafeScroll(snapshot: snapshot) {
                VStack(alignment: .leading, spacing: 12) {
                    if let value = account?.snapshot {
                        quotaRows(value, used: true)
                    }
                    if let account, !account.message.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            if account.snapshot == nil {
                                Label(account.state == "not_signed_in" || account.state == "expired" ? "Claude 로그인 확인" : "사용량 확인", systemImage: "info.circle")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            Text(account.message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 13))
                    }
                    if selectedHost == ClaudeUsageAccount.localID, account?.snapshot == nil, !usage.claudeMessage.isEmpty {
                        Text(usage.claudeMessage).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if selectedHost == ClaudeUsageAccount.localID { notificationButton(.claude) }
                else {
                    Label(usage.demo ? "예시 연결" : (alerts.remoteStatus[selectedHost] ?? "연결 확인 중"), systemImage: "network")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Text("위치별 로그인 계정 기준").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
            }
        }
    }
    // ImageRenderer omits native scrolling surfaces; keep the example host tabs visible in exports.
    private var claudeLocationTabs: some View {
        HStack(spacing: 6) {
            ForEach(usage.claudeLocations, id: \.self) { host in
                Button { usage.selectedClaudeHost = host } label: {
                    Label(host == ClaudeUsageAccount.localID ? "이 Mac" : host,
                          systemImage: host == ClaudeUsageAccount.localID ? "laptopcomputer" : "network")
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(selectedHost == host ? Color.accentColor : .white.opacity(0.55))
                        .background(.white.opacity(selectedHost == host ? 0.1 : 0.035), in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel((host == ClaudeUsageAccount.localID ? "이 Mac" : host) + " Claude 사용량")
                    .accessibilityAddTraits(selectedHost == host ? .isSelected : [])
            }
        }
    }
    private func connectionEmpty(symbol: String, title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 13) {
            Spacer(minLength: 6)
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            Button(action: action) {
                Text(button).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 22).padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.8), in: Capsule())
            }.buttonStyle(.plain).disabled(usage.demo)
            Spacer(minLength: 6)
        }.frame(maxWidth: .infinity)
    }
    private func notificationButton(_ provider: AIProvider) -> some View {
        Button { alerts.connect(provider) } label: {
            Label("완료·승인 알림", systemImage: alerts.configured.contains(provider) ? "bell.badge.fill" : "bell")
                .font(.system(size: 10)).foregroundStyle(alerts.configured.contains(provider) ? Color.accentColor : .white.opacity(0.45))
        }.buttonStyle(.plain).disabled(alerts.demo)
            .accessibilityLabel(provider.title + (alerts.configured.contains(provider) ? " 알림 연결 해제" : " 알림 연결"))
    }
    private func quotaRows(_ value: UsageSnapshot, used: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(value.windows) { window in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(window.label).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(Int((used ? window.used : window.remaining).rounded()))% \(used ? "사용" : "남음")")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule().fill(window.remaining <= 20 ? Color.red : Color.accentColor)
                                .frame(width: geometry.size.width * min(100, max(0, used ? window.used : window.remaining)) / 100)
                        }
                    }.frame(height: 5)
                    if let reset = window.resetsAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(reset <= context.date ? "초기화 시각 지남 · 새 데이터 대기" : "초기화 " + reset.formatted(.relative(presentation: .numeric)))
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                                .help(reset.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
            }
            Text((value.stale ? "이전 조회 · " : "마지막 확인 · ") + value.sampledAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9)).foregroundStyle(value.stale ? .orange.opacity(0.8) : .white.opacity(0.35))
        }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }
}
