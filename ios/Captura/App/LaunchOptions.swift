import Foundation

/// Process-level facts the app checks at launch.
enum AppEnvironment {
    /// The app is the host of the unit tests: show a plain screen and never touch the
    /// microphone, the network, the Keychain-backed model or background tasks.
    static var isHostingTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}

/// Debug-only automation for end-to-end runs in the Simulator, so a script can record
/// without tapping the screen:
///
///     xcrun simctl launch "iPhone 17" org.example.captura \
///         -CapturaAutoRecordSeconds 6 -CapturaChunkSeconds 3
///
/// `-CapturaAutoRecordSeconds N` starts recording when the app becomes active and stops
/// after N seconds. `-CapturaChunkSeconds N` shortens the 15-minute rotation. Release
/// builds compile none of this and always use the defaults.
struct LaunchOptions: Equatable, Sendable {
    var autoRecordSeconds: TimeInterval?
    var chunkSeconds: TimeInterval?

    static let autoRecordFlag = "-CapturaAutoRecordSeconds"
    static let chunkFlag = "-CapturaChunkSeconds"
    static let autoRecordRange: ClosedRange<TimeInterval> = 1...3600
    static let chunkRange: ClosedRange<TimeInterval> = 2...(15 * 60)

    static var current: LaunchOptions {
        #if DEBUG
        return parse(ProcessInfo.processInfo.arguments)
        #else
        return LaunchOptions()
        #endif
    }

    #if DEBUG
    /// Values outside the allowed ranges, or that are not numbers, are ignored.
    static func parse(_ arguments: [String]) -> LaunchOptions {
        func value(after flag: String, in range: ClosedRange<TimeInterval>) -> TimeInterval? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                  let number = TimeInterval(arguments[index + 1]), number.isFinite, range.contains(number)
            else { return nil }
            return number
        }
        return LaunchOptions(
            autoRecordSeconds: value(after: autoRecordFlag, in: autoRecordRange),
            chunkSeconds: value(after: chunkFlag, in: chunkRange)
        )
    }
    #endif
}
