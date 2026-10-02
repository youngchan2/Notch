import SwiftUI

struct AIAlertsView: View {
    @ObservedObject var alerts: AIAlertBridge
    var snapshot = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 알림").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("지우기") { alerts.clearAll() }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
            }
            if !alerts.message.isEmpty {
                Text(alerts.message).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
            PreviewSafeScroll(snapshot: snapshot) {
                VStack(spacing: 8) {
                    if alerts.items.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "bell").font(.system(size: 25, weight: .light)).foregroundStyle(Color.accentColor)
                            Text("응답과 승인 요청을 이곳에서").font(.system(size: 13, weight: .medium))
                            Text("연결 설정은 AI 사용량 탭에서 할 수 있어요.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }.frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    ForEach(alerts.items) { event in
                        HStack(spacing: 10) {
                            Button { alerts.open(event) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: event.symbol).font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.accentColor).frame(width: 32, height: 32)
                                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(event.provider.title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                            if event.preview { Text("예시").font(.system(size: 9)).foregroundStyle(.orange) }
                                            Spacer()
                                            Text(event.createdAt, style: .time).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                                        }
                                        Text(event.conversationTitle ?? event.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                        Text(event.conversationTitle == nil ? event.detail : event.title + (event.tool.isEmpty ? "" : " · " + event.tool))
                                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("\(event.provider.title), \(event.title), \(event.detail), \(event.openingAction)")
                                .help(event.conversationLabel + " · " + event.openingAction)
                            Button { alerts.dismiss(event) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).padding(7).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.4)).accessibilityLabel(event.provider.title + " 알림 지우기")
                        }.padding(12).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                    }
                }
            }
            Text("알림을 누르면 해당 대화가 열립니다. · 승인은 해당 앱에서 진행해 주세요.")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 20).foregroundStyle(.white)
    }
}

struct AIAlertCountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.system(size: 8, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(.black).padding(.horizontal, 3)
            .frame(minWidth: 13, minHeight: 13).background(Color.accentColor, in: Capsule())
            .fixedSize().allowsHitTesting(false).accessibilityLabel("보관된 알림 \(count)개")
    }
}

struct CompactAIAlert: View {
    let event: AIEvent
    let geometry: IslandGeometry
    var emphasized = false
    var notificationCount = 0
    var body: some View {
        Group {
            if geometry.hasNotch { notchContent }
            else { capsuleContent }
        }.foregroundStyle(.white)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(event.provider.title), \(event.conversationLabel), \(event.title), 보관된 알림 \(notificationCount)개, 클릭하여 \(event.openingAction)")
            .help(event.conversationLabel + " · " + event.openingAction)
    }

    private var notchContent: some View {
        NotchAlertLayout(geometry: geometry) {
            Image(systemName: event.kind == .permission ? "hand.raised.fill" : "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
        } trailing: {
            Text(event.kind == .permission ? "승인 대기" : "응답 완료")
                .font(.system(size: 9, weight: .semibold)).lineLimit(1)
                .foregroundStyle(emphasized ? Color.accentColor : .white)
        } detail: {
            HStack(spacing: 6) {
                Text(event.provider == .claude ? "Claude" : "Codex")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.55)).fixedSize()
                Text(event.conversationLabel).font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if notificationCount > 0 { AIAlertCountBadge(count: notificationCount) }
                Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var capsuleContent: some View {
        HStack(spacing: 8) {
            Image(systemName: event.kind == .permission ? "hand.raised.fill" : "checkmark.circle.fill")
                .font(.system(size: emphasized ? 28 : 14, weight: .semibold)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                if emphasized {
                    Text(event.provider == .claude ? "Claude" : "Codex")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                }
                Text(event.conversationLabel).font(.system(size: emphasized ? 12 : 11, weight: .semibold))
                    .lineLimit(emphasized ? 2 : 1).truncationMode(.tail)
            }.frame(maxWidth: 160, alignment: .leading)
            Spacer(minLength: 4)
            Text(event.kind == .permission ? "승인 대기" : "응답 완료")
                .font(.system(size: emphasized ? 13 : 11, weight: .semibold)).lineLimit(1)
                .foregroundStyle(emphasized ? Color.accentColor : .white)
            if notificationCount > 0 { AIAlertCountBadge(count: notificationCount) }
            Image(systemName: "arrow.up.forward").font(.system(size: emphasized ? 11 : 9)).foregroundStyle(.white.opacity(0.7))
        }.padding(.horizontal, 18)
    }
}
