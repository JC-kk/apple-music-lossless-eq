import Foundation
import MusicKit

final class MediaAuthorizationController {
    static func requestIfNeeded(completion: @escaping (Bool) -> Void) {
        if #available(macOS 12.0, *) {
            let status = MusicAuthorization.currentStatus
            switch status {
            case .authorized:
                completion(true)
            case .notDetermined:
                Task {
                    let newStatus = await MusicAuthorization.request()
                    completion(newStatus == .authorized)
                }
            default:
                completion(false)
            }
        } else {
            completion(false)
        }
    }
}
