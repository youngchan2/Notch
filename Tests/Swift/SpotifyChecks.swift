import AppKit

@MainActor func runSpotifyChecks(_ check: (Bool, String) -> Void) {
    func until(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }
    var song = Track.demo
    song.playing = false
    var attempts = 0
    let retry = SpotifyBridge(runningProcess: { 100 }, read: { _, _ in
        attempts += 1
        return attempts == 1 ? SpotifyReadResult(errorCode: -1712) : SpotifyReadResult(track: song)
    })
    retry.refresh()
    check(until { retry.connection == .unavailable }, "A Spotify timeout is reported as unavailable, not permission denied")
    retry.refresh()
    check(until { retry.connection == .ready && retry.active && retry.track?.playing == false },
          "A failed Spotify read releases the queue and a subsequent paused track reconnects")

    let permission = SpotifyBridge(runningProcess: { 100 }, read: { _, prompt in
        prompt ? SpotifyReadResult(track: song) : SpotifyReadResult(errorCode: -1744)
    })
    permission.refresh()
    check(until { permission.connection == .needsPermission }, "Background polling requests no Spotify consent dialog")
    permission.connect()
    check(until { permission.connection == .ready }, "The Connect action requests consent and retries the read")
    check(SpotifyReadResult(errorCode: -1743).connection == .denied, "Denied Spotify consent retains its settings guidance")

    var pid: pid_t? = 100
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var oldReads = 0
    let lifecycle = SpotifyBridge(runningProcess: { pid }, read: { process, _ in
        if process == 100 {
            oldReads += 1
            if oldReads == 2 { entered.signal(); release.wait() }
        }
        var result = song
        result.id = String(process)
        return SpotifyReadResult(track: result)
    })
    lifecycle.refresh()
    check(until { lifecycle.track?.id == "100" }, "Spotify's running process supplies the initial track")
    lifecycle.refresh()
    check(entered.wait(timeout: .now() + 2) == .success, "The lifecycle regression exercises a pending Spotify read")
    pid = nil
    lifecycle.refresh()
    check(lifecycle.connection == .closed && !lifecycle.active, "Spotify termination clears music even during an outstanding read")
    pid = 200
    lifecycle.refresh()
    release.signal()
    check(until { lifecycle.track?.id == "200" && lifecycle.connection == .ready },
          "A late response from the old Spotify process is discarded and the new process reconnects")

    let pending = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
    let deferredConnect = SpotifyBridge(runningProcess: { 300 }, read: { _, prompt in
        if !prompt { pending.signal(); proceed.wait() }
        return prompt ? SpotifyReadResult(track: song) : SpotifyReadResult(errorCode: -1744)
    })
    deferredConnect.refresh()
    check(pending.wait(timeout: .now() + 2) == .success, "The consent regression exercises an in-progress background read")
    deferredConnect.connect()
    proceed.signal()
    check(until { deferredConnect.connection == .ready }, "Connect clicked during a pending read is handled immediately afterward")
}
