import AppKit

@MainActor func runAIAlertPresentationChecks(_ check: (Bool, String) -> Void) {
    let date = Date(timeIntervalSince1970: 5000)
    func event(_ provider: AIProvider, _ kind: AIEventKind, session: String = "presentation") -> AIEvent {
        AIEvent(provider: provider, session: session, kind: kind, project: "Presentation check", tool: "",
                createdAt: date, targetBundleID: provider.bundleID)
    }
    for hasNotch in [true, false] {
        let geometry = IslandGeometry(centerX: 800, topY: 900, notchWidth: 184,
                                      topHeight: hasNotch ? 32 : 24, hasNotch: hasNotch)
        for provider in AIProvider.allCases {
            for kind in [AIEventKind.completed, .permission] {
                let incoming = event(provider, kind)
                let context = "\(hasNotch ? "Notch" : "Glass") \(provider) \(kind)"
                var queue = AIAlertQueue()
                queue.receive(incoming, now: date)
                let arrival = geometry.hitRect(expanded: false, active: queue.unreadCount > 0,
                                               alert: queue.banner != nil, aiAlertEmphasized: true)
                queue.tick(now: date.addingTimeInterval(4.9))
                check(queue.banner?.id == incoming.id, context + " shows a full five-second banner")
                queue.tick(now: date.addingTimeInterval(5))
                check(queue.banner == nil && queue.unreadCount == 1 && queue.items == [incoming],
                      context + " expires without deleting or reading the alert")
                let compact = geometry.hitRect(expanded: false, active: queue.unreadCount > 0, alert: queue.banner != nil)
                check(compact.width == geometry.compactWidth && compact.height == geometry.compactHeight
                      && compact.width < arrival.width && compact.height < arrival.height,
                      context + " returns to the compact badge geometry")
                queue.setInboxVisible(true)
                check(queue.unreadCount == 0 && queue.items == [incoming], context + " viewing preserves the alert and clears only its count")
                check(queue.pendingCount == (kind == .permission ? 1 : 0), context + " viewing does not approve pending work")
                queue.setInboxVisible(false)
                queue.tick(now: date.addingTimeInterval(30))
                let idle = geometry.hitRect(expanded: false, active: queue.unreadCount > 0, alert: queue.banner != nil)
                check(queue.unreadCount == 0 && queue.banner == nil && idle.width == geometry.idleWidth
                      && idle.height == geometry.topHeight, context + " stays idle after leaving the inbox")
                // The next turn in the same conversation must not inherit its predecessor's read state.
                var next = incoming; next.id = UUID(); next.kind = .completed; next.createdAt = date.addingTimeInterval(31)
                queue.receive(next, now: next.createdAt)
                check(queue.unreadCount == 1 && queue.banner?.id == next.id, context + " a new turn shows a fresh badge")
            }
        }
    }
    var queue = AIAlertQueue()
    let completed = event(.codex, .completed)
    let approval = event(.claude, .permission, session: "approval")
    queue.receive(completed, now: date)
    queue.receive(approval, now: date)
    check(queue.unreadCount == 2 && queue.banner?.id == approval.id, "Approval interrupts completion without losing either unread item")
    queue.setInboxVisible(true)
    check(queue.unreadCount == 0 && queue.storedCount == 2 && queue.banner == nil, "Opening the inbox acknowledges active and queued banners together")
    queue.tick(now: date.addingTimeInterval(6))
    check(queue.banner == nil, "A queued banner cannot reappear after the inbox was viewed")
    var visible = event(.claude, .completed, session: "visible"); visible.createdAt = date.addingTimeInterval(7)
    queue.receive(visible, now: visible.createdAt)
    check(queue.storedCount == 3 && queue.unreadCount == 0 && queue.banner == nil, "Arrival while the inbox is visible is stored and already viewed")
    queue.setInboxVisible(false)
    queue.receive(visible, now: date.addingTimeInterval(8))
    check(queue.unreadCount == 0 && queue.banner == nil, "Duplicate delivery cannot make a viewed item unread")
    var fresh = event(.codex, .permission, session: "fresh"); fresh.createdAt = date.addingTimeInterval(9)
    queue.receive(fresh, now: fresh.createdAt)
    check(queue.unreadCount == 1 && queue.storedCount == 4, "Only a newly delivered notification is counted after leaving the inbox")
    queue.dismiss(completed.id)
    check(queue.unreadCount == 1 && queue.storedCount == 3, "Deleting an already viewed item does not change the new count")
    queue.acknowledge(fresh.id)
    check(queue.unreadCount == 0 && queue.pendingCount == 2 && queue.banner == nil, "Opening a permission's destination acknowledges its badge without approving it")
    var resumed = fresh; resumed.id = UUID(); resumed.kind = .resumed; resumed.createdAt = date.addingTimeInterval(10)
    queue.receive(resumed, now: resumed.createdAt)
    check(queue.pendingCount == 1 && queue.unreadCount == 0, "Actual work resumption still clears an acknowledged approval")
    queue.tick(now: date.addingTimeInterval(3610))
    check(queue.items.isEmpty && queue.unreadCount == 0 && queue.banner == nil, "Viewed and unviewed history share the existing one-hour cleanup policy")
    let bridge = AIAlertBridge(demo: true)
    bridge.preview()
    bridge.preview(permission: true)
    bridge.setInboxVisible(true)
    check(bridge.storedCount == 2 && bridge.unreadCount == 0 && bridge.banner == nil && !bridge.isEmphasized,
          "Inbox visibility reaches the presentation bridge without deleting notifications")
    bridge.preview()
    check(bridge.storedCount == 2 && bridge.unreadCount == 0 && bridge.banner == nil, "Bridge arrivals while viewing the inbox stay acknowledged")
    bridge.setInboxVisible(false)
    bridge.preview()
    check(bridge.unreadCount == 1 && bridge.banner != nil && bridge.isEmphasized, "Bridge resumes notification presentation when the inbox closes")
    bridge.poll(now: Date().addingTimeInterval(6))
    check(bridge.banner == nil && bridge.unreadCount == 1 && !bridge.isEmphasized, "A new banner still times out after viewing the inbox")
    bridge.clearAll()
    check(bridge.items.isEmpty && bridge.unreadCount == 0 && bridge.banner == nil, "Deleting all clears both history and the unread count")
}
