import Foundation
import AppKit
import CoreAudio

private enum PlaybackMode {
    case stopped
    case paused
    case playing
}

private struct PlaybackStateMachine {
    private(set) var mode: PlaybackMode = .stopped
    private(set) var trackID: String?
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var album: String?
    private(set) var albumArtist: String?
    private(set) var duration: Double?
    private(set) var playbackStartTime: Date?

    private var anchorPosition: Double?
    private var anchorDate: Date?

    var isPlaying: Bool {
        mode == .playing
    }

    var hasTrack: Bool {
        title != nil
    }

    mutating func applyPlayerInfo(_ info: MusicPlayerInfo, trackID: String, now: Date) -> Bool {
        let changedTrack = self.trackID != trackID
        if changedTrack {
            self.trackID = trackID
            title = info.title
            artist = info.artist
            album = info.album
            albumArtist = info.albumArtist
            duration = info.duration
            if let position = info.position {
                anchorPosition = position
                anchorDate = now
            } else if info.isPlaying {
                anchorPosition = 0
                anchorDate = now
            } else {
                anchorPosition = nil
                anchorDate = nil
            }
            playbackStartTime = info.isPlaying ? now : nil
        } else {
            title = info.title ?? title
            artist = info.artist ?? artist
            album = info.album ?? album
            albumArtist = info.albumArtist ?? albumArtist
            duration = info.duration ?? duration
            if let position = info.position {
                anchorPosition = position
                anchorDate = now
            } else if info.isPlaying {
                if anchorPosition == nil {
                    anchorPosition = 0
                }
                anchorDate = now
            }
            if info.isPlaying, playbackStartTime == nil {
                playbackStartTime = now
            }
        }

        mode = info.isPlaying ? .playing : .paused
        if !info.isPlaying {
            playbackStartTime = nil
        }
        return changedTrack
    }

    mutating func applyMediaRemote(_ info: NowPlayingInfo, trackID: String, now: Date, trustPlaybackState: Bool) -> Bool {
        let changedTrack = self.trackID != trackID
        if changedTrack || self.trackID == nil {
            self.trackID = trackID
            title = info.title
            artist = info.artist
            album = info.album
            albumArtist = info.artist
            duration = info.duration
        } else {
            title = title ?? info.title
            artist = artist ?? info.artist
            album = album ?? info.album
            duration = info.duration ?? duration
        }

        applyMediaRemoteTiming(info, now: now)

        guard trustPlaybackState else {
            return changedTrack
        }

        mode = info.isPlaying ? .playing : .paused
        playbackStartTime = info.isPlaying ? (playbackStartTime ?? now) : nil
        return changedTrack
    }

    mutating func applyMediaRemoteTiming(_ info: NowPlayingInfo, now: Date) {
        duration = info.duration ?? duration

        guard let elapsed = info.elapsed else {
            return
        }

        let projected: Double
        if mode == .playing, info.isPlaying, let timestamp = info.timestamp {
            projected = elapsed + now.timeIntervalSince(timestamp)
        } else {
            projected = elapsed
        }

        anchorPosition = min(max(projected, 0), duration ?? projected)
        anchorDate = mode == .playing ? now : nil
    }

    mutating func applyDuration(_ duration: Double?) {
        guard let duration, duration > 0 else { return }
        self.duration = duration
    }

    mutating func applyExternalPosition(_ position: Double, now: Date) {
        guard position.isFinite, position >= 0 else {
            return
        }

        anchorPosition = min(position, duration ?? position)
        anchorDate = mode == .playing ? now : nil
        if mode == .playing, playbackStartTime == nil {
            playbackStartTime = now.addingTimeInterval(-position)
        }
    }

    mutating func applyTransport(_ info: MusicPlayerInfo, now: Date) {
        duration = info.duration ?? duration
        mode = info.isPlaying ? .playing : .paused
        if let position = info.position {
            applyExternalPosition(position, now: now)
        }

        playbackStartTime = info.isPlaying ? (playbackStartTime ?? now) : nil
    }

    mutating func stop() {
        mode = .stopped
        trackID = nil
        title = nil
        artist = nil
        album = nil
        albumArtist = nil
        duration = nil
        playbackStartTime = nil
        anchorPosition = nil
        anchorDate = nil
    }

    mutating func project(now: Date = Date()) {
        guard mode == .playing,
              let anchorPosition,
              let anchorDate else {
            return
        }

        let projected = anchorPosition + now.timeIntervalSince(anchorDate)
        self.anchorPosition = min(projected, duration ?? projected)
        self.anchorDate = now
    }

    func projectedPosition(now: Date = Date()) -> Double? {
        guard let anchorPosition else {
            return nil
        }

        guard mode == .playing, let anchorDate else {
            return anchorPosition
        }

        let projected = anchorPosition + now.timeIntervalSince(anchorDate)
        return min(projected, duration ?? projected)
    }
}

final class SampleRateModel: ObservableObject {
    @Published var currentTrackTitle: String = "Not playing"
    @Published var artistName: String = ""
    @Published var albumName: String = ""
    @Published var artwork: NSImage?
    @Published var isPlaying: Bool = false
    @Published var elapsedSeconds: Double?
    @Published var durationSeconds: Double?
    @Published var trackSampleRateDisplay: String = "Unknown"
    @Published var outputDeviceName: String = "Unknown"
    @Published var outputDeviceIcon: String = "speaker.wave.2.fill"
    @Published var outputSampleRateDisplay: String = "Unknown"
    @Published var outputSampleRate: Double?
    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var currentOutputDeviceID: AudioDeviceID?
    @Published var availableSampleRates: [Double] = []
    @Published var outputVolume: Double = 0.5
    @Published var volumeAvailable: Bool = false
    @Published var sampleRateSourceDisplay: String = "Unknown"
    @Published var logStatusMessage: String = ""
    @Published var statusMessage: String = ""
    @Published var musicSettingsWarnings: [String] = []
    @Published var autoSwitchEnabled: Bool = true
    @Published var logParserEnabled: Bool = true {
        didSet {
            if logParserEnabled {
                startLogParser()
            } else {
                logController.stop()
                logStatusMessage = "Log parser disabled"
            }
        }
    }

    private let mediaRemoteController = MediaRemoteController()
    private let musicController = MusicController()
    private let logController = LogStreamController()
    private let audioController = AudioDeviceController()
    private let artworkFetchQueue = DispatchQueue(label: "Choritsu.music-artwork")
    private let positionFetchQueue = DispatchQueue(label: "Choritsu.music-position")
    private let musicSnapshotQueue = DispatchQueue(label: "Choritsu.music-snapshot")
    private let artworkDownloadSession = URLSession(configuration: .ephemeral)
    private var timer: Timer?
    private var playbackState = PlaybackStateMachine()
    private var latestLogCandidateRate: Double?
    private var stableLogSampleRate: Double?
    private var stableLogSampleRateAt: Date?
    private var stableSampleRateSourceDisplay: String = "Log (locked)"
    private var logRateWindow: [(rate: Double, date: Date, weight: Int)] = []
    private var lastHandledRate: Double?
    private var maxRateForCurrentTrack: Double?
    private var lastTrackTitle: String?
    private var lastTrackID: String?
    private var currentAlbumID: String?
    private var notificationTrackName: String?
    private var lastPlayerInfoAt: Date?
    private var hasLookaheadActivity = false
    private var detectedPreBufferRate: Double?
    private var albumRateCache: [String: Double] = [:]
    private var albumRateCacheOrder: [String] = []
    private var lastAppliedSampleRate: Double?
    private var lastAppliedAt: Date?
    private var lastArtworkData: Data?
    private var artworkTrackTitle: String?
    private var lastArtworkURL: URL?
    private var lastMediaRemoteTrackID: String?
    private var lastMediaRemoteTrackAt: Date?
    private var lastMediaRemoteHadArtwork = false
    private var artworkFetchGeneration = 0
    private var isFetchingMusicPosition = false
    private var isFetchingMusicSnapshot = false
    private var isAdjustingVolume = false
    private var isSwitchingRate = false
    private var isPreemptivelyPaused = false
    private var preemptivePauseWork: DispatchWorkItem?
    private var playerInfoObserver: NSObjectProtocol?
    private let preemptivePauseTimeout: TimeInterval = 2.0
    private let safeSwitchWindow: TimeInterval = 0.3

    private let albumRateCacheKey = "albumRateCache"
    private let albumRateCacheOrderKey = "albumRateCacheOrder"
    private let maxAlbumRateCacheEntries = 128

    init() {
        loadAlbumRateCache()
        MediaAuthorizationController.requestIfNeeded { granted in
            DispatchQueue.main.async {
                if !granted {
                    self.statusMessage = "Media & Apple Music access denied in Privacy & Security."
                }
            }
        }
        startLogParser()
        startPlayerInfoObserver()
        refreshMusicSettingsWarnings()
        startPolling()
    }

    deinit {
        if let playerInfoObserver {
            musicController.removePlayerInfoObserver(playerInfoObserver)
        }
        preemptivePauseWork?.cancel()
        timer?.invalidate()
        logController.stop()
    }

    var menuBarTitle: String {
        trackSampleRateDisplay.contains("kHz") ? trackSampleRateDisplay : "SR"
    }

    func refreshNow() {
        updateState()
    }

    func togglePlayPause() {
        isPlaying.toggle()
        musicController.sendCommand(.playPause)
        scheduleQuickRefresh()
    }

    func nextTrack() {
        musicController.sendCommand(.nextTrack)
        scheduleQuickRefresh()
    }

    func previousTrack() {
        musicController.sendCommand(.previousTrack)
        scheduleQuickRefresh()
    }

    func beginVolumeAdjustment() {
        isAdjustingVolume = true
    }

    func endVolumeAdjustment() {
        isAdjustingVolume = false
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        outputVolume = clamped
        _ = audioController.setOutputVolume(Float(clamped))
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID) {
        guard deviceID != currentOutputDeviceID else { return }

        if audioController.setDefaultOutputDevice(deviceID) {
            currentOutputDeviceID = deviceID
            statusMessage = "Switched output device"
        } else {
            statusMessage = "Failed to switch output device"
        }
        scheduleQuickRefresh()
    }

    func selectSampleRate(_ rate: Double) {
        // Manual choice would be reverted by auto switch within a second,
        // so disengage it when they conflict.
        if autoSwitchEnabled,
           let stableLogSampleRate,
           abs(stableLogSampleRate - rate) >= 1.0 {
            autoSwitchEnabled = false
        }

        if audioController.setDefaultOutputSampleRate(rate) {
            outputSampleRate = rate
            outputSampleRateDisplay = formatSampleRate(rate)
            statusMessage = "Output set to \(formatSampleRate(rate))"
        } else {
            statusMessage = "Failed to set output sample rate"
        }
        scheduleQuickRefresh()
    }

    private func scheduleQuickRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.updateState()
        }
    }

    func dumpNowPlaying() {
        mediaRemoteController.dumpNowPlayingInfo()
    }

    func restartLogParser() {
        startLogParser()
    }

    func dumpRecentLogs() {
        logController.dumpRecentLines()
    }

    func refreshMusicSettingsWarnings() {
        musicSettingsWarnings = MusicSettingsAdvisor.warnings()
    }

    func fixMusicSettings() {
        if MusicSettingsAdvisor.applyRecommendedSettings() {
            refreshMusicSettingsWarnings()
            statusMessage = musicSettingsWarnings.isEmpty
                ? "Music settings ready for lossless playback"
                : "Music settings updated; reopen Music to apply"
        } else {
            statusMessage = "Couldn't update Music settings"
        }
    }

    private func startPolling() {
        updateState()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateState()
        }
    }

    private func startPlayerInfoObserver() {
        playerInfoObserver = musicController.observePlayerInfo { [weak self] info in
            self?.handlePlayerInfo(info)
        }
    }

    private func handlePlayerInfo(_ info: MusicPlayerInfo) {
        applyMusicPlayerInfo(info, allowArtworkFallback: true, scheduleRefresh: true)
    }

    private func applyMusicPlayerInfo(_ info: MusicPlayerInfo,
                                      allowArtworkFallback: Bool,
                                      scheduleRefresh: Bool) {
        guard info.hasTrackMetadata, let title = info.title else {
            if info.state == "Stopped" || info.state == "Unknown" {
                notificationTrackName = nil
                lastPlayerInfoAt = nil
                playbackState.stop()
                publishPlaybackState()
                cancelPreemptivePause()
            }
            logStatusMessage = "Skipping transient notification"
            return
        }

        let notificationID = identityKey([title, info.artist, info.album])

        notificationTrackName = title
        let now = Date()
        lastPlayerInfoAt = now
        if shouldPreferRecentMediaRemote(overMusicTrackID: notificationID) {
            playbackState.applyTransport(info, now: now)
            publishPlaybackState(now: now)
            if scheduleRefresh {
                scheduleQuickRefresh()
            }
            return
        }

        let trackChanged = playbackState.applyPlayerInfo(info, trackID: notificationID, now: now)
        publishPlaybackState(now: now)
        if trackChanged {
            resetArtworkForTrack(title)
        }
        if allowArtworkFallback, (trackChanged || artwork == nil) {
            scheduleMusicArtworkFetch(for: title)
        }

        updateTrackIdentity(title: title,
                            artist: info.artist,
                            album: info.album,
                            albumArtist: info.albumArtist,
                            isPlaying: info.isPlaying,
                            position: playbackState.projectedPosition(now: now))
        if scheduleRefresh {
            scheduleQuickRefresh()
        }
    }

    private func updateState() {
        let outputDevice = audioController.defaultOutputDeviceInfo()

        playbackState.project()
        publishPlaybackState()
        scheduleMusicSnapshotSync()
        scheduleMusicPositionSync()

        outputDeviceName = outputDevice.name
        outputDeviceIcon = outputDevice.iconName
        outputSampleRate = outputDevice.sampleRate
        outputSampleRateDisplay = formatSampleRate(outputDevice.sampleRate)
        currentOutputDeviceID = outputDevice.id
        outputDevices = audioController.outputDevices()
        if let deviceID = outputDevice.id {
            availableSampleRates = audioController.availableSampleRates(deviceID: deviceID)
        } else {
            availableSampleRates = []
        }

        if !isAdjustingVolume {
            if let volumeInfo = audioController.outputVolumeInfo() {
                volumeAvailable = volumeInfo.settable
                outputVolume = Double(volumeInfo.volume)
            } else {
                volumeAvailable = false
            }
        }

        mediaRemoteController.nowPlayingInfo { [weak self] result in
            DispatchQueue.main.async {
                self?.applyNowPlaying(result,
                                      outputDevice: outputDevice)
            }
        }
    }

    private func applyNowPlaying(_ result: NowPlayingResult,
                                 outputDevice: OutputDeviceInfo) {
        if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
            currentTrackTitle = "Unavailable"
            trackSampleRateDisplay = "Unknown"
            statusMessage = errorMessage
            return
        }

        let info = result.info

        let resolvedTitle = info?.title ?? ""

        if shouldPreservePlayerInfoState(for: resolvedTitle) {
            updateArtwork(info?.artworkData, artworkURL: info?.artworkURL)
            playbackState.project()
            publishPlaybackState()
            updateCurrentSampleRateDisplay()
            statusMessage = isPlaying ? playbackStatusWithoutLogRate() : "Paused"
            return
        }

        guard !resolvedTitle.isEmpty else {
            playbackState.stop()
            publishPlaybackState()
            updateArtwork(nil)
            updateCurrentSampleRateDisplay()
            statusMessage = ""
            return
        }

        let resolvedArtist = info?.artist
        let resolvedAlbum = info?.album

        if let info {
            let mediaRemoteTrackID = identityKey([resolvedTitle, resolvedArtist, resolvedAlbum])
            rememberMediaRemoteTrack(mediaRemoteTrackID,
                                     hasArtwork: info.artworkData != nil || info.artworkURL != nil)
            let trustMediaRemotePlayback = lastPlayerInfoAt == nil || !musicController.isRunning
            if trustMediaRemotePlayback {
                _ = playbackState.applyMediaRemote(info,
                                                   trackID: mediaRemoteTrackID,
                                                   now: Date(),
                                                   trustPlaybackState: true)
            } else if isCurrentPlaybackTrack(id: mediaRemoteTrackID,
                                             title: resolvedTitle,
                                             artist: resolvedArtist,
                                             album: resolvedAlbum) {
                playbackState.applyMediaRemoteTiming(info, now: Date())
            }
            applyMediaRemoteSampleRate(info.sampleRate)
        }
        publishPlaybackState()

        updateTrackIdentity(title: resolvedTitle,
                            artist: resolvedArtist,
                            album: resolvedAlbum,
                            albumArtist: resolvedArtist,
                            isPlaying: isPlaying,
                            position: elapsedSeconds)
        updateArtwork(info?.artworkData, artworkURL: info?.artworkURL)

        updateCurrentSampleRateDisplay()

        guard isPlaying else {
            statusMessage = "Paused"
            return
        }

        guard autoSwitchEnabled else {
            statusMessage = "Auto switch disabled"
            return
        }

        guard let targetSampleRate = stableLogSampleRate else {
            statusMessage = playbackStatusWithoutLogRate()
            return
        }

        switchToRateIfSafe(targetSampleRate,
                           reason: "Now playing update",
                           position: elapsedSeconds)
    }

    private func publishPlaybackState(now: Date = Date()) {
        guard playbackState.hasTrack else {
            currentTrackTitle = "Not playing"
            artistName = ""
            albumName = ""
            isPlaying = false
            elapsedSeconds = nil
            durationSeconds = nil
            return
        }

        currentTrackTitle = playbackState.title ?? "Not playing"
        artistName = playbackState.artist ?? ""
        albumName = playbackState.album ?? ""
        isPlaying = playbackState.isPlaying
        elapsedSeconds = playbackState.projectedPosition(now: now)
        durationSeconds = playbackState.duration
    }

    private func scheduleMusicPositionSync() {
        guard playbackState.hasTrack,
              musicController.isRunning,
              !isFetchingMusicPosition else {
            return
        }

        isFetchingMusicPosition = true
        positionFetchQueue.async { [weak self] in
            guard let self else { return }
            let position = self.musicController.playerPosition()
            DispatchQueue.main.async {
                self.isFetchingMusicPosition = false
                guard let position,
                      self.playbackState.hasTrack else {
                    return
                }

                let now = Date()
                self.playbackState.applyExternalPosition(position, now: now)
                self.publishPlaybackState(now: now)
            }
        }
    }

    private func scheduleMusicSnapshotSync() {
        guard musicController.isRunning,
              !isFetchingMusicSnapshot else {
            return
        }

        isFetchingMusicSnapshot = true
        musicSnapshotQueue.async { [weak self] in
            guard let self else { return }
            let info = self.musicController.currentPlayerInfo()
            DispatchQueue.main.async {
                self.isFetchingMusicSnapshot = false
                guard let info else {
                    return
                }
                self.applyMusicPlayerInfo(info,
                                          allowArtworkFallback: self.artwork == nil,
                                          scheduleRefresh: false)
            }
        }
    }

    private func playbackStatusWithoutLogRate() -> String {
        if let outputSampleRate {
            return "Playing at \(formatSampleRate(outputSampleRate))"
        }

        return "Playing"
    }

    private func shouldPreservePlayerInfoState(for mediaRemoteTitle: String) -> Bool {
        guard mediaRemoteTitle.isEmpty || mediaRemoteTitle == "Unknown",
              notificationTrackName != nil,
              musicController.isRunning else {
            return false
        }

        return true
    }

    private func rememberMediaRemoteTrack(_ trackID: String, hasArtwork: Bool) {
        guard !trackID.isEmpty else { return }
        lastMediaRemoteTrackID = trackID
        lastMediaRemoteTrackAt = Date()
        lastMediaRemoteHadArtwork = hasArtwork
    }

    private func shouldPreferRecentMediaRemote(overMusicTrackID musicTrackID: String) -> Bool {
        guard lastMediaRemoteHadArtwork,
              let lastMediaRemoteTrackID,
              !lastMediaRemoteTrackID.isEmpty,
              !musicTrackID.isEmpty,
              lastMediaRemoteTrackID != musicTrackID,
              let lastMediaRemoteTrackAt,
              Date().timeIntervalSince(lastMediaRemoteTrackAt) < 3.0,
              playbackState.hasTrack else {
            return false
        }

        return true
    }

    private func isCurrentPlaybackTrack(id: String,
                                        title: String,
                                        artist: String?,
                                        album: String?) -> Bool {
        if id == playbackState.trackID {
            return true
        }

        guard normalizedIdentityComponent(title) == normalizedIdentityComponent(playbackState.title ?? "") else {
            return false
        }

        let mediaArtist = normalizedIdentityComponent(artist ?? "")
        let stateArtist = normalizedIdentityComponent(playbackState.artist ?? "")
        if !mediaArtist.isEmpty, !stateArtist.isEmpty, mediaArtist != stateArtist {
            return false
        }

        let mediaAlbum = normalizedIdentityComponent(album ?? "")
        let stateAlbum = normalizedIdentityComponent(playbackState.album ?? "")
        if !mediaAlbum.isEmpty, !stateAlbum.isEmpty, mediaAlbum != stateAlbum {
            return false
        }

        return true
    }

    private func updateArtwork(_ data: Data?, artworkURL: URL? = nil) {
        let trackChanged = artworkTrackTitle != currentTrackTitle

        if let data {
            applyArtworkData(data, trackTitle: currentTrackTitle)
            return
        }

        if let artworkURL {
            scheduleArtworkDownload(artworkURL, title: currentTrackTitle)
            return
        }

        guard trackChanged else { return }
        resetArtworkForTrack(currentTrackTitle)
        scheduleMusicArtworkFetch(for: currentTrackTitle)
    }

    private func resetArtworkForTrack(_ title: String) {
        artworkTrackTitle = title
        lastArtworkData = nil
        lastArtworkURL = nil
        if title == "Not playing" || title == "Unavailable" {
            artwork = nil
        }
    }

    private func scheduleArtworkDownload(_ url: URL, title: String) {
        guard url != lastArtworkURL || artworkTrackTitle != title || artwork == nil else {
            return
        }

        artworkFetchGeneration += 1
        let generation = artworkFetchGeneration
        artworkTrackTitle = title
        lastArtworkURL = url

        artworkDownloadSession.dataTask(with: url) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  !data.isEmpty else {
                return
            }

            DispatchQueue.main.async {
                guard self.artworkFetchGeneration == generation,
                      self.currentTrackTitle == title else {
                    return
                }
                self.applyArtworkData(data, trackTitle: title)
            }
        }.resume()
    }

    private func scheduleMusicArtworkFetch(for title: String, attempt: Int = 0) {
        guard !title.isEmpty,
              title != "Not playing",
              title != "Unavailable" else {
            return
        }

        artworkFetchGeneration += 1
        let generation = artworkFetchGeneration
        let delay: TimeInterval = attempt == 0 ? 0.25 : 0.8

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.artworkFetchGeneration == generation,
                  self.currentTrackTitle == title else {
                return
            }

            self.artworkFetchQueue.async { [weak self] in
                guard let self else { return }
                let data = self.musicController.currentTrackArtwork()
                DispatchQueue.main.async {
                    guard self.artworkFetchGeneration == generation,
                          self.currentTrackTitle == title else {
                        return
                    }

                    if let data, !data.isEmpty {
                        self.applyArtworkData(data, trackTitle: title)
                    } else if attempt < 2 {
                        self.scheduleMusicArtworkFetch(for: title, attempt: attempt + 1)
                    }
                }
            }
        }
    }

    private func applyArtworkData(_ data: Data, trackTitle: String) {
        let sameData = data == lastArtworkData
        artworkTrackTitle = trackTitle
        guard !sameData else { return }
        lastArtworkData = data
        artwork = NSImage(data: data)
    }

    func formatSampleRate(_ sampleRate: Double?) -> String {
        guard let sampleRate, sampleRate > 0 else {
            return "Unknown"
        }

        let khz = sampleRate / 1000.0
        let rounded = (khz * 10).rounded() / 10

        if abs(rounded - rounded.rounded()) < 0.05 {
            return String(format: "%.0f kHz", rounded)
        }

        return String(format: "%.1f kHz", rounded)
    }

    private func startLogParser() {
        logController.onSampleRate = { [weak self] rate, message in
            DispatchQueue.main.async {
                self?.handleLogSampleRate(rate, message: message)
            }
        }

        logController.onTrackName = { [weak self] trackName in
            DispatchQueue.main.async {
                self?.handleLogTrackName(trackName)
            }
        }

        logController.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.logStatusMessage = status
            }
        }

        logController.start()
    }

    private func applyLogAutoSwitch(sampleRate: Double) {
        guard autoSwitchEnabled else { return }

        let outputDevice = audioController.defaultOutputDeviceInfo()
        guard let currentOutputRate = outputDevice.sampleRate,
              abs(currentOutputRate - sampleRate) >= 1.0 else {
            return
        }

        if let lastAppliedSampleRate,
           let lastAppliedAt,
           abs(lastAppliedSampleRate - sampleRate) < 1.0,
           Date().timeIntervalSince(lastAppliedAt) < 2 {
            return
        }

        switchToRateIfSafe(sampleRate,
                           reason: "Log locked",
                           position: elapsedSeconds)
    }

    private func handleLogTrackName(_ trackName: String) {
        guard !trackName.isEmpty,
              let notificationTrackName,
              normalizedIdentityComponent(trackName) == normalizedIdentityComponent(notificationTrackName),
              !hasLookaheadActivity else {
            return
        }
        hasLookaheadActivity = true
        logStatusMessage = "Lookahead detected: \(trackName)"
    }

    private func handleLogSampleRate(_ rate: Double, message: String?) {
        let now = Date()
        guard let candidateRate = quantizeLogRate(rate) else {
            return
        }

        latestLogCandidateRate = candidateRate
        maxRateForCurrentTrack = max(maxRateForCurrentTrack ?? candidateRate, candidateRate)
        let trustedInputFormat = isTrustedInputFormatMessage(message)

        if hasLookaheadActivity,
           let stableLogSampleRate,
           abs(stableLogSampleRate - candidateRate) >= 1.0 {
            detectedPreBufferRate = candidateRate
            logStatusMessage = "Pre-buffer detected: \(formatSampleRate(candidateRate))"
            return
        }

        if isPreemptivelyPaused, trustedInputFormat {
            lockSampleRate(candidateRate, reason: "Log fast lock")
            return
        }

        if shouldDebounceStartupRate(candidateRate) {
            logStatusMessage = "Startup rate \(formatSampleRate(candidateRate)) differs from handled rate — debouncing"
            return
        }

        let weight: Int
        if trustedInputFormat {
            weight = 6
        } else if message?.contains("Derived from frames/duration") ?? false {
            weight = 3
        } else {
            weight = 1
        }
        logRateWindow.append((rate: candidateRate, date: now, weight: weight))
        logRateWindow = logRateWindow.filter { now.timeIntervalSince($0.date) <= 6.0 }

        let totalWeight = logRateWindow.reduce(0) { $0 + $1.weight }
        let counts = Dictionary(grouping: logRateWindow, by: { $0.rate }).mapValues { $0.reduce(0) { $0 + $1.weight } }
        guard let dominant = counts.max(by: { $0.value < $1.value }) else {
            return
        }

        let dominantRate = dominant.key
        let dominantWeight = dominant.value
        let dominance = totalWeight > 0 ? Double(dominantWeight) / Double(totalWeight) : 0.0

        if stableLogSampleRate == nil {
            if dominantWeight >= 6 && dominance >= 0.7 {
                lockSampleRate(dominantRate, reason: "Log locked")
            } else {
                sampleRateSourceDisplay = "Log (estimating)"
                trackSampleRateDisplay = "Estimating"
                logStatusMessage = "Log estimating \(formatSampleRate(dominantRate)) (\(dominantWeight)/\(totalWeight))"
            }
        } else if dominantRate != stableLogSampleRate {
            let stableAge = now.timeIntervalSince(stableLogSampleRateAt ?? now)
            if dominantWeight >= 9 && dominance >= 0.85 && stableAge > 3 {
                lockSampleRate(dominantRate, reason: "Log switched")
            }
        }

        if message != nil, stableLogSampleRate == nil {
            logStatusMessage = "Log estimating \(formatSampleRate(dominantRate)) (\(dominantWeight)/\(totalWeight))"
        }
    }

    private func isTrustedInputFormatMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.range(of: "Input format:", options: .caseInsensitive) != nil
            && message.range(of: "ch,", options: .caseInsensitive) != nil
            && message.range(of: "Hz", options: .caseInsensitive) != nil
    }

    private func shouldDebounceStartupRate(_ rate: Double) -> Bool {
        guard !isPreemptivelyPaused,
              let playbackStartTime = playbackState.playbackStartTime,
              let lastHandledRate,
              abs(lastHandledRate - rate) >= 1.0,
              Date().timeIntervalSince(playbackStartTime) < 2.0 else {
            return false
        }
        return true
    }

    private func resetLogLock(reason: String) {
        stableLogSampleRate = nil
        stableLogSampleRateAt = nil
        stableSampleRateSourceDisplay = "Log (locked)"
        logRateWindow.removeAll()
        latestLogCandidateRate = nil
        hasLookaheadActivity = false
        maxRateForCurrentTrack = nil
        trackSampleRateDisplay = "Unknown"
        sampleRateSourceDisplay = "Unknown"
        logStatusMessage = reason
    }

    private func updateCurrentSampleRateDisplay() {
        if let stableLogSampleRate {
            trackSampleRateDisplay = formatSampleRate(stableLogSampleRate)
            sampleRateSourceDisplay = stableSampleRateSourceDisplay
        } else if latestLogCandidateRate != nil {
            trackSampleRateDisplay = "Estimating"
            sampleRateSourceDisplay = "Log (estimating)"
        } else {
            trackSampleRateDisplay = "Unknown"
            sampleRateSourceDisplay = "Unknown"
        }
    }

    private func applyMediaRemoteSampleRate(_ sampleRate: Double?) {
        guard stableLogSampleRate == nil,
              let sampleRate,
              let candidateRate = quantizeLogRate(sampleRate) else {
            return
        }

        stableLogSampleRate = candidateRate
        stableLogSampleRateAt = Date()
        stableSampleRateSourceDisplay = "MediaRemote"
        trackSampleRateDisplay = formatSampleRate(candidateRate)
        sampleRateSourceDisplay = stableSampleRateSourceDisplay
        logStatusMessage = "MediaRemote sample rate at \(formatSampleRate(candidateRate))"
        lastHandledRate = candidateRate

        if let currentAlbumID {
            rememberAlbumRate(candidateRate, albumID: currentAlbumID)
        }
    }

    private func lockSampleRate(_ rate: Double, reason: String) {
        stableLogSampleRate = rate
        stableLogSampleRateAt = Date()
        stableSampleRateSourceDisplay = "Log (locked)"
        trackSampleRateDisplay = formatSampleRate(rate)
        sampleRateSourceDisplay = stableSampleRateSourceDisplay
        logStatusMessage = "\(reason) at \(formatSampleRate(rate))"
        if let currentAlbumID {
            rememberAlbumRate(rate, albumID: currentAlbumID)
        }
        lastHandledRate = rate
        applyLogAutoSwitch(sampleRate: rate)
    }

    private func quantizeLogRate(_ rate: Double) -> Double? {
        let candidates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000]
        let nearest = candidates.min(by: { abs($0 - rate) < abs($1 - rate) })
        guard let nearest else { return nil }

        let diffRatio = abs(nearest - rate) / nearest
        if diffRatio <= 0.008 {
            return nearest
        }

        return nil
    }

    private func updateTrackIdentity(title: String,
                                     artist: String?,
                                     album: String?,
                                     albumArtist: String?,
                                     isPlaying: Bool,
                                     position: Double?) {
        guard !title.isEmpty else { return }

        notificationTrackName = title
        let trackID = identityKey([title, artist, album])
        let albumID = identityKey([albumArtist ?? artist, album])
        guard !trackID.isEmpty else { return }

        let previousTrackID = lastTrackID
        let previousAlbumID = currentAlbumID
        lastTrackTitle = title
        currentAlbumID = albumID.isEmpty ? nil : albumID

        guard previousTrackID != nil, previousTrackID != trackID else {
            lastTrackID = trackID
            return
        }

        lastTrackID = trackID
        let sameAlbum = !albumID.isEmpty && albumID == previousAlbumID
        handleTrackBoundary(albumID: albumID.isEmpty ? nil : albumID,
                            sameAlbum: sameAlbum,
                            isPlaying: isPlaying,
                            position: position)
    }

    private func handleTrackBoundary(albumID: String?,
                                     sameAlbum: Bool,
                                     isPlaying: Bool,
                                     position: Double?) {
        resetLogLock(reason: "Track changed")

        if let detectedPreBufferRate {
            self.detectedPreBufferRate = nil
            stableLogSampleRate = detectedPreBufferRate
            stableSampleRateSourceDisplay = "Log (pre-buffer)"
            trackSampleRateDisplay = formatSampleRate(detectedPreBufferRate)
            sampleRateSourceDisplay = stableSampleRateSourceDisplay
            if let albumID {
                rememberAlbumRate(detectedPreBufferRate, albumID: albumID)
            }
            switchToRateIfSafe(detectedPreBufferRate,
                               reason: "Pre-buffer",
                               position: position)
            return
        }

        if let albumID, let cachedRate = albumRateCache[albumID] {
            stableLogSampleRate = cachedRate
            stableSampleRateSourceDisplay = "Album cache"
            trackSampleRateDisplay = formatSampleRate(cachedRate)
            sampleRateSourceDisplay = stableSampleRateSourceDisplay

            if sameAlbum {
                statusMessage = "Same album cached at \(formatSampleRate(cachedRate)); not switching mid-album"
            } else {
                switchToRateIfSafe(cachedRate,
                                   reason: "Album cache",
                                   position: position)
            }
            return
        }

        if sameAlbum {
            statusMessage = "Same album, cache miss — learning rate without pausing"
            return
        }

        if isPlaying, autoSwitchEnabled, isSafeTrackBoundary(position) {
            statusMessage = playbackStatusWithoutLogRate()
        }
    }

    private func beginPreemptivePause() {
        guard !isPreemptivelyPaused,
              stableLogSampleRate == nil,
              musicController.pauseIfPlaying() else {
            return
        }

        isPreemptivelyPaused = true
        statusMessage = "Preemptive pause — waiting for sample rate"

        preemptivePauseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPreemptivelyPaused else { return }
            self.isPreemptivelyPaused = false
            if self.musicController.resumeIfPaused() {
                self.verifyPlaybackResumed()
            }
            self.statusMessage = "Preemptive pause timeout — continuing playback"
        }
        preemptivePauseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + preemptivePauseTimeout, execute: work)
    }

    private func finishPreemptivePauseIfNeeded() {
        preemptivePauseWork?.cancel()
        preemptivePauseWork = nil
        guard isPreemptivelyPaused else { return }
        isPreemptivelyPaused = false
        if musicController.resumeIfPaused() {
            verifyPlaybackResumed()
        }
    }

    private func cancelPreemptivePause() {
        preemptivePauseWork?.cancel()
        preemptivePauseWork = nil
        isPreemptivelyPaused = false
    }

    private func switchToRateIfSafe(_ rate: Double, reason: String, position: Double?) {
        guard autoSwitchEnabled, !isSwitchingRate else { return }
        guard isSafeTrackBoundary(position) || isPreemptivelyPaused else {
            statusMessage = "Skipping rate matching — track already in progress"
            return
        }

        let outputDevice = audioController.defaultOutputDeviceInfo()
        if let currentOutputRate = outputDevice.sampleRate,
           abs(currentOutputRate - rate) < 1.0 {
            statusMessage = "Output already at \(formatSampleRate(rate))"
            finishPreemptivePauseIfNeeded()
            return
        }

        isSwitchingRate = true
        let switched = audioController.setDefaultOutputSampleRate(rate)
        isSwitchingRate = false

        if switched {
            lastAppliedSampleRate = rate
            lastAppliedAt = Date()
            lastHandledRate = rate
            outputSampleRate = rate
            outputSampleRateDisplay = formatSampleRate(rate)
            statusMessage = "\(reason): switched output to \(formatSampleRate(rate))"
        } else {
            statusMessage = "Failed to switch output sample rate"
        }

        finishPreemptivePauseIfNeeded()
    }

    private func isSafeTrackBoundary(_ position: Double?) -> Bool {
        guard let position else { return true }
        return position <= safeSwitchWindow
    }

    private func verifyPlaybackResumed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.statusMessage = "Playback resume requested"
        }
    }

    private func rememberAlbumRate(_ rate: Double, albumID: String) {
        guard !albumID.isEmpty else { return }
        albumRateCache[albumID] = rate
        albumRateCacheOrder.removeAll { $0 == albumID }
        albumRateCacheOrder.append(albumID)

        while albumRateCacheOrder.count > maxAlbumRateCacheEntries {
            let removed = albumRateCacheOrder.removeFirst()
            albumRateCache.removeValue(forKey: removed)
        }
        saveAlbumRateCache()
    }

    private func loadAlbumRateCache() {
        let defaults = UserDefaults.standard
        albumRateCache = defaults.dictionary(forKey: albumRateCacheKey) as? [String: Double] ?? [:]
        albumRateCacheOrder = defaults.stringArray(forKey: albumRateCacheOrderKey) ?? Array(albumRateCache.keys)
    }

    private func saveAlbumRateCache() {
        let defaults = UserDefaults.standard
        defaults.set(albumRateCache, forKey: albumRateCacheKey)
        defaults.set(albumRateCacheOrder, forKey: albumRateCacheOrderKey)
    }

    private func identityKey(_ components: [String?]) -> String {
        components
            .compactMap { normalizedIdentityComponent($0 ?? "") }
            .filter { !$0.isEmpty }
            .joined(separator: "\u{1f}")
    }

    private func normalizedIdentityComponent(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
