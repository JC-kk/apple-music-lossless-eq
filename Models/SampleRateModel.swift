import Foundation
import AppKit
import CoreAudio

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
    private var timer: Timer?
    private var latestLogCandidateRate: Double?
    private var stableLogSampleRate: Double?
    private var stableLogSampleRateAt: Date?
    private var logRateWindow: [(rate: Double, date: Date, weight: Int)] = []
    private var lastHandledRate: Double?
    private var maxRateForCurrentTrack: Double?
    private var playbackStartTime: Date?
    private var lastTrackTitle: String?
    private var lastTrackID: String?
    private var currentAlbumID: String?
    private var lastNotificationTrackID: String?
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
        guard info.hasTrackMetadata, let title = info.title else {
            if info.state == "Stopped" || info.state == "Unknown" {
                notificationTrackName = nil
                lastPlayerInfoAt = nil
                cancelPreemptivePause()
            }
            logStatusMessage = "Skipping transient notification"
            return
        }

        let notificationID = identityKey([title, info.artist, info.album, info.albumArtist])
        if lastNotificationTrackID == notificationID, isPlaying == info.isPlaying {
            return
        }
        lastNotificationTrackID = notificationID

        notificationTrackName = title
        lastPlayerInfoAt = Date()
        currentTrackTitle = title
        artistName = info.artist ?? ""
        albumName = info.album ?? ""
        isPlaying = info.isPlaying

        updateTrackIdentity(title: title,
                            artist: info.artist,
                            album: info.album,
                            albumArtist: info.albumArtist,
                            isPlaying: info.isPlaying,
                            position: info.position)
        scheduleQuickRefresh()
    }

    private func updateState() {
        let outputDevice = audioController.defaultOutputDeviceInfo()
        let fallbackTrack = TrackFetchResult(track: nil, errorMessage: nil)

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
                                      outputDevice: outputDevice,
                                      fallback: fallbackTrack)
            }
        }
    }

    private func applyNowPlaying(_ result: NowPlayingResult,
                                 outputDevice: OutputDeviceInfo,
                                 fallback: TrackFetchResult) {
        if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
            currentTrackTitle = "Unavailable"
            trackSampleRateDisplay = "Unknown"
            statusMessage = errorMessage
            return
        }

        let info = result.info
        let fallbackTrack = fallback.track

        var resolvedTitle = info?.title ?? ""
        if resolvedTitle.isEmpty || resolvedTitle == "Unknown", let fallbackTrack {
            resolvedTitle = fallbackTrack.title
        }

        guard !resolvedTitle.isEmpty else {
            currentTrackTitle = "Not playing"
            artistName = ""
            albumName = ""
            isPlaying = false
            elapsedSeconds = nil
            durationSeconds = nil
            updateArtwork(nil)
            updateCurrentSampleRateDisplay()
            statusMessage = fallback.errorMessage ?? ""
            return
        }

        let resolvedArtist = info?.artist ?? fallbackTrack?.artist
        let resolvedAlbum = info?.album ?? fallbackTrack?.album
        currentTrackTitle = resolvedTitle
        artistName = resolvedArtist ?? ""
        albumName = resolvedAlbum ?? ""
        isPlaying = info?.isPlaying ?? fallbackTrack?.isPlaying ?? false
        durationSeconds = info?.duration ?? fallbackTrack?.duration
        updateElapsed(info: info, fallback: fallbackTrack)
        updateTrackIdentity(title: resolvedTitle,
                            artist: resolvedArtist,
                            album: resolvedAlbum,
                            albumArtist: resolvedArtist,
                            isPlaying: isPlaying,
                            position: elapsedSeconds)
        updateArtwork(info?.artworkData)

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
            statusMessage = "Waiting for log sample rate"
            return
        }

        switchToRateIfSafe(targetSampleRate,
                           reason: "Now playing update",
                           position: elapsedSeconds)
    }

    private func updateElapsed(info: NowPlayingInfo?, fallback: TrackInfo?) {
        if let elapsed = info?.elapsed {
            if isPlaying, let timestamp = info?.timestamp {
                let projected = elapsed + Date().timeIntervalSince(timestamp)
                elapsedSeconds = min(projected, durationSeconds ?? projected)
            } else {
                elapsedSeconds = elapsed
            }
        } else {
            elapsedSeconds = fallback?.position
        }
    }

    private func updateArtwork(_ data: Data?) {
        let trackChanged = artworkTrackTitle != currentTrackTitle
        artworkTrackTitle = currentTrackTitle

        var resolved = data
        if resolved == nil {
            // MediaRemote artwork is unavailable; ask Music directly, but
            // only once per track since the AppleScript round trip is slow.
            guard trackChanged else { return }
            resolved = currentTrackTitle == "Not playing" ? nil : musicController.currentTrackArtwork()
        }

        guard resolved != lastArtworkData else { return }
        lastArtworkData = resolved
        artwork = resolved.flatMap { NSImage(data: $0) }
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
              let playbackStartTime,
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
            sampleRateSourceDisplay = "Log (locked)"
        } else if latestLogCandidateRate != nil {
            trackSampleRateDisplay = "Estimating"
            sampleRateSourceDisplay = "Log (estimating)"
        } else {
            trackSampleRateDisplay = "Unknown"
            sampleRateSourceDisplay = "Unknown"
        }
    }

    private func lockSampleRate(_ rate: Double, reason: String) {
        stableLogSampleRate = rate
        stableLogSampleRateAt = Date()
        trackSampleRateDisplay = formatSampleRate(rate)
        sampleRateSourceDisplay = "Log (locked)"
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
            if isPlaying, playbackStartTime == nil {
                playbackStartTime = Date()
            }
            return
        }

        lastTrackID = trackID
        playbackStartTime = isPlaying ? Date() : nil
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
            trackSampleRateDisplay = formatSampleRate(detectedPreBufferRate)
            sampleRateSourceDisplay = "Log (pre-buffer)"
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
            trackSampleRateDisplay = formatSampleRate(cachedRate)
            sampleRateSourceDisplay = "Album cache"

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

        guard isPlaying, autoSwitchEnabled, isSafeTrackBoundary(position) else {
            return
        }

        beginPreemptivePause()
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

        let pausedForSwitch = isPreemptivelyPaused || musicController.pauseIfPlaying()
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

        if isPreemptivelyPaused {
            finishPreemptivePauseIfNeeded()
        } else if pausedForSwitch {
            if musicController.resumeIfPaused() {
                verifyPlaybackResumed()
            }
        }
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
