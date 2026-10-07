import Foundation

/// What may go to the unified log as public text.
enum LogPrivacy {
    /// The error's domain and code only. A Foundation or AVFoundation error description
    /// carries file paths (the app container and chunk names, which embed the recording
    /// time); log that part with `privacy: .private`.
    static func publicSummary(of error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
