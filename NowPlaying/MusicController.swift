import Foundation
import AppKit
import ScriptingBridge

struct MusicPlayerInfo {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let state: String?
    let position: Double?
    let duration: Double?

    var isPlaying: Bool {
        state == "Playing"
    }

    var hasTrackMetadata: Bool {
        !(title ?? "").isEmpty
    }

    init(userInfo: [AnyHashable: Any]) {
        title = MusicPlayerInfo.string(userInfo["Name"])
        artist = MusicPlayerInfo.string(userInfo["Artist"])
        album = MusicPlayerInfo.string(userInfo["Album"])
        albumArtist = MusicPlayerInfo.string(userInfo["Album Artist"])
        state = MusicPlayerInfo.string(userInfo["Player State"])
        position = MusicPlayerInfo.double(userInfo["Player Position"])
        duration = MusicPlayerInfo.duration(userInfo["Total Time"])
            ?? MusicPlayerInfo.duration(userInfo["Duration"])
            ?? MusicPlayerInfo.duration(userInfo["Track Duration"])
    }

    init(title: String?,
         artist: String?,
         album: String?,
         albumArtist: String?,
         state: String?,
         position: Double?,
         duration: Double?) {
        self.title = MusicPlayerInfo.string(title)
        self.artist = MusicPlayerInfo.string(artist)
        self.album = MusicPlayerInfo.string(album)
        self.albumArtist = MusicPlayerInfo.string(albumArtist)
        self.state = MusicPlayerInfo.string(state)
        self.position = position
        self.duration = duration
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    private static func duration(_ value: Any?) -> Double? {
        guard let value = double(value), value > 0 else {
            return nil
        }

        // Music's distributed notification has historically used milliseconds
        // for "Total Time", while MediaRemote reports seconds.
        return value > 10_000 ? value / 1_000 : value
    }
}

enum MusicCommand: String {
    case playPause = "playpause"
    case nextTrack = "next track"
    case previousTrack = "back track"
}

final class MusicController {
    private let playerInfoNotification = Notification.Name("com.apple.Music.playerInfo")

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    func observePlayerInfo(_ handler: @escaping (MusicPlayerInfo) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: playerInfoNotification,
                                                            object: nil,
                                                            queue: .main) { notification in
            handler(MusicPlayerInfo(userInfo: notification.userInfo ?? [:]))
        }
    }

    func removePlayerInfoObserver(_ observer: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(observer)
    }

    func playerPosition() -> Double? {
        guard isRunning,
              let music = SBApplication(bundleIdentifier: "com.apple.Music"),
              let value = music.value(forKey: "playerPosition") as? NSNumber else {
            return nil
        }

        let position = value.doubleValue
        return position.isFinite && position >= 0 ? position : nil
    }

    func currentPlayerInfo() -> MusicPlayerInfo? {
        guard isRunning,
              let music = SBApplication(bundleIdentifier: "com.apple.Music"),
              let track = music.value(forKey: "currentTrack") as? NSObject else {
            return nil
        }

        let title = track.value(forKey: "name") as? String
        guard !(title ?? "").isEmpty else {
            return nil
        }

        let state = playerStateName(from: music.value(forKey: "playerState"))
        let duration = numericValue(track.value(forKey: "duration"))
        return MusicPlayerInfo(title: title,
                               artist: track.value(forKey: "artist") as? String,
                               album: track.value(forKey: "album") as? String,
                               albumArtist: track.value(forKey: "albumArtist") as? String,
                               state: state,
                               position: playerPosition(),
                               duration: duration)
    }

    func sendCommand(_ command: MusicCommand) {
        if sendFastCommand(command) {
            return
        }

        let scriptSource = """
        tell application \"Music\"
            if it is running then
                \(command.rawValue)
            end if
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
    }

    func pauseIfPlaying() -> Bool {
        guard playerState() == "playing" else {
            return false
        }

        if sendMusicEvent(eventID: fourCharCode("Paus")) {
            return true
        }

        let scriptSource = """
        tell application \"Music\"
            if it is running then
                set stateText to (player state as text)
                if stateText is \"playing\" then
                    pause
                    return \"paused\"
                end if
            end if
        end tell
        return \"\"
        """

        return executeString(scriptSource) == "paused"
    }

    func resumeIfPaused() -> Bool {
        guard playerState() == "paused" else {
            return false
        }

        if sendMusicEvent(eventID: fourCharCode("PlPs")) {
            return true
        }

        let scriptSource = """
        tell application \"Music\"
            if it is running then
                set stateText to (player state as text)
                if stateText is \"paused\" then
                    playpause
                    return \"playing\"
                end if
            end if
        end tell
        return \"\"
        """

        return executeString(scriptSource) == "playing"
    }

    func playerState() -> String? {
        let scriptSource = """
        tell application \"Music\"
            if it is running then
                return (player state as text)
            end if
        end tell
        return \"\"
        """

        guard let state = executeString(scriptSource)?.lowercased(),
              !state.isEmpty else {
            return nil
        }
        return state
    }

    func currentTrackArtwork() -> Data? {
        let scriptSource = """
        tell application \"Music\"
            if it is running then
                try
                    return (get data of artwork 1 of current track)
                end try
            end if
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return nil
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            return nil
        }

        let data = output.data
        return data.isEmpty ? nil : data
    }

    private func executeString(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            return nil
        }

        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            return nil
        }
        return output.stringValue
    }

    private func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let doubleValue = number.doubleValue
            return doubleValue.isFinite && doubleValue > 0 ? doubleValue : nil
        }

        if let doubleValue = value as? Double, doubleValue.isFinite, doubleValue > 0 {
            return doubleValue
        }

        return nil
    }

    private func playerStateName(from value: Any?) -> String? {
        guard let number = value as? NSNumber else {
            return nil
        }

        switch FourCharCode(number.uint32Value) {
        case fourCharCode("kPSP"):
            return "Playing"
        case fourCharCode("kPSp"):
            return "Paused"
        case fourCharCode("kPSS"):
            return "Stopped"
        default:
            return nil
        }
    }

    private func sendFastCommand(_ command: MusicCommand) -> Bool {
        switch command {
        case .playPause:
            return sendMusicEvent(eventID: fourCharCode("PlPs"))
        case .nextTrack:
            return sendMusicEvent(eventID: fourCharCode("Next"))
        case .previousTrack:
            return sendMusicEvent(eventID: fourCharCode("Prev"))
        }
    }

    private func sendMusicEvent(eventID: AEEventID) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !running.isEmpty else {
            return false
        }

        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Music")
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: fourCharCode("hook"),
                                                      eventID: eventID,
                                                      targetDescriptor: target,
                                                      returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 0.25)
            return true
        } catch {
            return false
        }
    }

    private func fourCharCode(_ value: String) -> FourCharCode {
        value.utf8.reduce(FourCharCode(0)) { ($0 << 8) + FourCharCode($1) }
    }
}

enum MusicSettingsAdvisor {
    private static let musicDomain = "com.apple.Music"

    static func warnings() -> [String] {
        guard let domain = UserDefaults.standard.persistentDomain(forName: musicDomain) else {
            return []
        }

        var warnings: [String] = []

        if let losslessEnabled = firstBool(in: domain, keys: ["losslessAudioEnabled", "losslessEnabled"]),
           !losslessEnabled {
            warnings.append("Lossless Audio is disabled")
        }

        if let streamingQuality = firstInt(in: domain,
                                           keys: ["streamingBitrate",
                                                  "streamingQuality",
                                                  "preferredStreamingBitrate",
                                                  "streamingBitrateWifi"]),
           streamingQuality < 3 {
            warnings.append("Streaming quality is not Hi-Res Lossless")
        }

        if let downloadQuality = firstInt(in: domain,
                                          keys: ["preferredDownloadBitrate",
                                                 "downloadBitrate",
                                                 "downloadQuality"]),
           downloadQuality < 3 {
            warnings.append("Download quality is not Hi-Res Lossless")
        }

        let mutatingPlaybackKeys = [
            "optimizeSongVolume",
            "iTunesSoundCheck",
            "soundCheckEnabled",
            "soundEnhancerEnabled",
            "TransitionsEnabled",
            "crossfadeEnabled",
            "equalizerEnabled"
        ]
        for key in mutatingPlaybackKeys where boolValue(domain[key]) == true {
            warnings.append(playbackWarningName(for: key))
        }

        if let amount = numberValue(domain["soundEnhancerAmount"]), amount > 0 {
            warnings.append("Sound Enhancer is enabled")
        }

        return Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings
    }

    static func applyRecommendedSettings() -> Bool {
        quitMusicIfRunning()

        var success = true
        for key in ["losslessAudioEnabled", "losslessEnabled"] {
            success = writeDefault(key: key, type: "-bool", value: "true") && success
        }

        for key in ["streamingBitrate",
                    "streamingQuality",
                    "preferredStreamingBitrate",
                    "streamingBitrateWifi",
                    "preferredDownloadBitrate",
                    "downloadBitrate",
                    "downloadQuality"] {
            success = writeDefault(key: key, type: "-int", value: "3") && success
        }

        for key in ["optimizeSongVolume",
                    "iTunesSoundCheck",
                    "soundCheckEnabled",
                    "soundEnhancerEnabled",
                    "TransitionsEnabled",
                    "crossfadeEnabled",
                    "equalizerEnabled"] {
            success = writeDefault(key: key, type: "-bool", value: "false") && success
        }

        success = writeDefault(key: "soundEnhancerAmount", type: "-int", value: "0") && success
        return success
    }

    private static func firstBool(in domain: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = boolValue(domain[key]) {
                return value
            }
        }
        return nil
    }

    private static func firstInt(in domain: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = numberValue(domain[key]) {
                return Int(value)
            }
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            let lower = value.lowercased()
            if ["true", "yes", "1"].contains(lower) { return true }
            if ["false", "no", "0"].contains(lower) { return false }
        }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func playbackWarningName(for key: String) -> String {
        switch key {
        case "equalizerEnabled":
            return "Music Equalizer is enabled"
        case "TransitionsEnabled", "crossfadeEnabled":
            return "Song Transitions are enabled"
        case "optimizeSongVolume", "iTunesSoundCheck", "soundCheckEnabled":
            return "Sound Check is enabled"
        case "soundEnhancerEnabled":
            return "Sound Enhancer is enabled"
        default:
            return "\(key) is enabled"
        }
    }

    private static func quitMusicIfRunning() {
        let source = """
        tell application \"Music\"
            if it is running then quit
        end tell
        """
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
    }

    private static func writeDefault(key: String, type: String, value: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", musicDomain, key, type, value]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
