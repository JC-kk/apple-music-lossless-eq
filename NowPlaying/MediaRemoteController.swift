import Foundation
import Dispatch
import Darwin

struct NowPlayingInfo {
    let title: String
    let artist: String?
    let album: String?
    let artworkData: Data?
    let artworkURL: URL?
    let sampleRate: Double?
    let isPlaying: Bool
    let elapsed: Double?
    let duration: Double?
    let timestamp: Date?
}

struct NowPlayingResult {
    let info: NowPlayingInfo?
    let errorMessage: String?
}

final class MediaRemoteController {
    private typealias NowPlayingCallback = @convention(block) (CFDictionary?) -> Void
    private typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping NowPlayingCallback) -> Void
    private typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void

    private let handle: UnsafeMutableRawPointer?
    private let getNowPlayingInfoFn: MRMediaRemoteGetNowPlayingInfoFunction?
    private let registerNowPlayingFn: MRMediaRemoteRegisterForNowPlayingNotificationsFunction?

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        if let handle {
            let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo")
            if let symbol {
                getNowPlayingInfoFn = unsafeBitCast(symbol, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
            } else {
                getNowPlayingInfoFn = nil
            }

            let registerSymbol = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications")
            if let registerSymbol {
                registerNowPlayingFn = unsafeBitCast(registerSymbol, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
                registerNowPlayingFn?(DispatchQueue.main)
            } else {
                registerNowPlayingFn = nil
            }
        } else {
            getNowPlayingInfoFn = nil
            registerNowPlayingFn = nil
        }
    }

    func nowPlayingInfo(completion: @escaping (NowPlayingResult) -> Void) {
        guard let getNowPlayingInfoFn else {
            completion(NowPlayingResult(info: nil,
                                        errorMessage: "MediaRemote unavailable."))
            return
        }

        getNowPlayingInfoFn(DispatchQueue.main) { info in
            guard let info else {
                completion(NowPlayingResult(info: nil, errorMessage: nil))
                return
            }

            let dict = info as NSDictionary
            let title = MediaRemoteController.extractTitle(from: dict) ?? "Unknown"
            let playbackRate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 1.0
            let isPlaying = playbackRate > 0.0

            let sampleRate = MediaRemoteController.extractSampleRate(from: dict)
            let artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String
            let album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String
            let artworkData = MediaRemoteController.extractArtworkData(from: dict)
            let artworkURL = MediaRemoteController.extractArtworkURL(from: dict)
            let duration = (dict["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue
            let elapsed = (dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue
            let timestamp = dict["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date

            let nowPlaying = NowPlayingInfo(title: title,
                                           artist: artist,
                                           album: album,
                                           artworkData: artworkData,
                                           artworkURL: artworkURL,
                                           sampleRate: sampleRate,
                                           isPlaying: isPlaying,
                                           elapsed: elapsed,
                                           duration: duration,
                                           timestamp: timestamp)
            completion(NowPlayingResult(info: nowPlaying, errorMessage: nil))
        }
    }

    func dumpNowPlayingInfo() {
        guard let getNowPlayingInfoFn else {
            print("MediaRemote unavailable.")
            return
        }

        getNowPlayingInfoFn(DispatchQueue.main) { info in
            guard let info else {
                print("MediaRemote: now playing info is nil.")
                return
            }

            let dict = info as NSDictionary
            print("MediaRemote Now Playing Info:")
            print(MediaRemoteController.prettyPrint(value: dict, indent: 0))
        }
    }

    private static func extractSampleRate(from dict: NSDictionary) -> Double? {
        if let known = numberValue(dict["sampleRate"]) {
            return known
        }

        if let known = numberValue(dict["kMRMediaRemoteNowPlayingInfoSampleRate"]) {
            return known
        }

        if let known = numberValue(dict["kMRMediaRemoteNowPlayingInfoAudioSampleRate"]) {
            return known
        }

        if let known = findNumber(in: dict, keyContains: "samplerate") {
            return known
        }

        return nil
    }

    private static func extractArtworkData(from value: Any) -> Data? {
        if let data = value as? Data, !data.isEmpty {
            return data
        }

        if let data = value as? NSData, data.length > 0 {
            return data as Data
        }

        if let dict = value as? NSDictionary {
            if let data = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, !data.isEmpty {
                return data
            }

            for (key, val) in dict {
                let keyString = String(describing: key).lowercased()
                if keyString.contains("artwork") || keyString.contains("image") || keyString.contains("cover") {
                    if let data = extractArtworkData(from: val) {
                        return data
                    }
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let data = extractArtworkData(from: item) {
                    return data
                }
            }
        }

        return nil
    }

    private static func extractArtworkURL(from dict: NSDictionary) -> URL? {
        let keys = [
            "kMRMediaRemoteNowPlayingInfoArtworkIdentifier",
            "kMRMediaRemoteNowPlayingInfoArtworkURL",
            "artworkURL",
            "artworkIdentifier"
        ]

        for key in keys {
            if let value = dict[key] as? String,
               let url = URL(string: value),
               url.scheme?.hasPrefix("http") == true {
                return url
            }
        }

        if let urlString = findString(in: dict, keyContains: "artwork"),
           let url = URL(string: urlString),
           url.scheme?.hasPrefix("http") == true {
            return url
        }

        return nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            let doubleValue = number.doubleValue
            return doubleValue > 0 ? doubleValue : nil
        }

        if let doubleValue = value as? Double, doubleValue > 0 {
            return doubleValue
        }

        return nil
    }

    private static func prettyPrint(value: Any, indent: Int) -> String {
        let prefix = String(repeating: "  ", count: indent)

        if let dict = value as? NSDictionary {
            var lines: [String] = ["\(prefix){"] 
            for (key, val) in dict {
                let keyDesc = String(describing: key)
                let valueDesc = prettyPrint(value: val, indent: indent + 1)
                lines.append("\(prefix)  \(keyDesc): \(valueDesc)")
            }
            lines.append("\(prefix)}")
            return lines.joined(separator: "\n")
        }

        if let array = value as? [Any] {
            var lines: [String] = ["\(prefix)["] 
            for item in array {
                lines.append(prettyPrint(value: item, indent: indent + 1))
            }
            lines.append("\(prefix)]")
            return lines.joined(separator: "\n")
        }

        return "\(prefix)\(String(describing: value))"
    }

    private static func extractTitle(from dict: NSDictionary) -> String? {
        if let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String {
            return title
        }

        if let title = dict["title"] as? String {
            return title
        }

        return findString(in: dict, keyContains: "title")
    }

    private static func findString(in value: Any, keyContains: String) -> String? {
        if let dict = value as? NSDictionary {
            for (key, val) in dict {
                if let keyString = key as? String,
                   keyString.lowercased().contains(keyContains),
                   let str = val as? String,
                   !str.isEmpty {
                    return str
                }

                if let nested = findString(in: val, keyContains: keyContains) {
                    return nested
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let nested = findString(in: item, keyContains: keyContains) {
                    return nested
                }
            }
        }

        return nil
    }

    private static func findNumber(in value: Any, keyContains: String) -> Double? {
        if let dict = value as? NSDictionary {
            for (key, val) in dict {
                if let keyString = key as? String,
                   keyString.lowercased().contains(keyContains),
                   let numeric = numberValue(val) {
                    return numeric
                }

                if let nested = findNumber(in: val, keyContains: keyContains) {
                    return nested
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let nested = findNumber(in: item, keyContains: keyContains) {
                    return nested
                }
            }
        }

        return nil
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }
}
