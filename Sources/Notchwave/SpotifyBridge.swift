import AppKit
import SwiftUI
import Carbon

@MainActor final class SpotifyBridge: ObservableObject {
    @Published var track: Track?
    @Published var artwork: NSImage?
    @Published var connection: Connection = .closed
    @Published var demo = false
    @Published var busy = false
    @Published var commandError: String?

    private let queue = DispatchQueue(label: "app.notchwave.spotify", qos: .utility)
    private var timer: Timer?
    private var notification: NSObjectProtocol?
    private var inFlight = false
    private var wantsPermission = false
    private var artworkTask: Task<Void, Never>?
    private var currentArtworkURL = ""
    private var artworkAttempts = 0
    private var artworkLoading = false
    private var generation = 0
    private let cache = NSCache<NSString, NSImage>()

    // A loaded Spotify track owns the music capsule even while playback is paused.
    var active: Bool { track != nil }

    func start() {
        cache.countLimit = 24
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.25
        notification = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    func setDemo(_ enabled: Bool) {
        generation += 1
        demo = enabled
        artworkTask?.cancel()
        artworkLoading = false
        artwork = nil
        currentArtworkURL = ""
        commandError = nil
        if enabled {
            var sample = Track.demo
            sample.sampledAt = Date()
            track = sample
            connection = .ready
        } else {
            track = nil
            refresh()
        }
    }

    func connect() { refresh(prompt: true) }

    func refresh(prompt: Bool = false) {
        if prompt { wantsPermission = true }
        guard !demo, !inFlight, !busy else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else {
            track = nil
            artwork = nil
            currentArtworkURL = ""
            connection = .closed
            return
        }
        inFlight = true
        let shouldPrompt = wantsPermission
        wantsPermission = false
        let requestGeneration = generation
        queue.async { [weak self] in
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.spotify.client")
            let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, shouldPrompt)
            if permission != noErr {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight = false
                    guard self.generation == requestGeneration else { return }
                    self.track = nil
                    self.artwork = nil
                    self.currentArtworkURL = ""
                    self.connection = permission == -1744 ? .needsPermission : .denied
                }
                return
            }
            let source = """
            with timeout of 4 seconds
                tell application id "com.spotify.client"
                    if player state is stopped then return {}
                    set t to current track
                    return {id of t, name of t, artist of t, album of t, artwork url of t, duration of t, player position, player state as text, shuffling, repeating, shuffling enabled, repeating enabled}
                end tell
            end timeout
            """
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let sample = result.flatMap { Track.decode($0) }
            let errorCode = error?[NSAppleScript.errorNumber] as? Int
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard self.generation == requestGeneration else { return }
                self.track = sample
                self.connection = errorCode == -1743 ? .denied : (errorCode != nil ? .unavailable : (sample == nil ? .idle : .ready))
                self.loadArtwork(sample?.artworkURL ?? "")
            }
        }
    }

    enum Command {
        case toggle, next, previous, seek(Double), shuffle, repeatMode
        var script: String {
            switch self {
            case .toggle: return "playpause"
            case .next: return "next track"
            case .previous: return "previous track"
            case .seek(let seconds): return "set player position to \(seconds)"
            case .shuffle: return "set shuffling to (not shuffling)"
            case .repeatMode: return "set repeating to (not repeating)"
            }
        }
    }

    func send(_ command: Command) {
        guard var song = track, !busy else { return }
        if case .shuffle = command, !song.canShuffle { return }
        if case .repeatMode = command, !song.canRepeat { return }
        let safeCommand: Command
        if case .seek(let value) = command {
            guard value.isFinite else { return }
            safeCommand = .seek(min(max(0, value), song.duration))
        } else { safeCommand = command }

        if demo {
            song.position = song.elapsed()
            song.sampledAt = Date()
            switch safeCommand {
            case .toggle: song.playing.toggle()
            case .next: song.position = 0; song.title = song.title == "A little closer" ? "Blue hour" : "A little closer"
            case .previous: song.position = 0; song.title = "A little closer"
            case .seek(let seconds): song.position = seconds
            case .shuffle: song.shuffling.toggle()
            case .repeatMode: song.repeating.toggle()
            }
            track = song
            return
        }
        busy = true
        commandError = nil
        generation += 1 // A read started before this command must not overwrite its result.
        let commandGeneration = generation
        queue.async { [weak self] in
            var error: NSDictionary?
            let source = "with timeout of 4 seconds\ntell application id \"com.spotify.client\" to \(safeCommand.script)\nend timeout"
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let failed = error != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard self.generation == commandGeneration else { return }
                if failed { self.commandError = "재생 제어에 실패했어요. 다시 시도해 주세요." }
                self.refresh()
            }
        }
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            commandError = "Mac용 Spotify 앱을 먼저 설치해 주세요."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func loadArtwork(_ address: String) {
        if currentArtworkURL != address {
            artworkTask?.cancel()
            artwork = nil
            currentArtworkURL = address
            artworkAttempts = 0
            artworkLoading = false
        }
        guard !address.isEmpty, artwork == nil, !artworkLoading,
              let url = URL(string: address), url.scheme == "https", artworkAttempts < 2 else { return }
        if let cached = cache.object(forKey: address as NSString) { artwork = cached; return }
        artworkAttempts += 1
        artworkLoading = true
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            defer { if self?.currentArtworkURL == address { self?.artworkLoading = false } }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, let self, self.currentArtworkURL == address, !self.demo,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      data.count < 12_000_000, let image = NSImage(data: data) else { return }
                self.cache.setObject(image, forKey: address as NSString)
                self.artwork = image
            } catch { /* Keep the music-note placeholder when offline. */ }
        }
    }
}
