import Foundation

/// No CPU fallback for an existing Metal stage. A processing failure is shown in the
/// viewer AND aborts the current render/export rather than emitting partially graded pixels.
enum GPUProcessingFailure {
    static let notification = Notification.Name("SpektraFilmStudio.GPUProcessingFailure")

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var epoch: UInt64 = 0
        var message = ""
    }
    private static let state = State()

    static func checkpoint() -> UInt64 {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.epoch
    }

    static func report(_ message: String) {
        state.lock.lock()
        state.epoch &+= 1
        state.message = message
        state.lock.unlock()
        NSLog("SpektraFilm Metal stage failed: %@", message)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: notification, object: message)
        }
    }

    static func requireSuccess(after checkpoint: UInt64) throws {
        state.lock.lock()
        let changed = state.epoch != checkpoint
        let reason = state.message
        state.lock.unlock()
        if changed {
            throw NSError(
                domain: "SpektraFilmStudio.GPUProcessingFailure", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "GPU image stage failed; export/preview aborted instead of emitting partial output. \(reason)"]
            )
        }
    }
}
