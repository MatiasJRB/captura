import Foundation
import XCTest
@testable import CapturaCore

/// A temporary directory per test, removed on deinit. Fictional audio bytes only.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(component: "captura-sync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions changed by a test before removing.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        if let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            for child in children {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func subdirectory(_ name: String) throws -> URL {
        let child = url.appending(component: name)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        return child
    }
}

enum Fixture {
    static let utc = TimeZone(identifier: "UTC")!
    static let baseDate = Date(timeIntervalSince1970: 1_791_300_000)
    static let deviceID = "test-device"

    /// Deterministic, non-repeating fictional bytes (not real audio; the sync layer
    /// never decodes audio).
    static func bytes(_ count: Int, seed: UInt8 = 7) -> Data {
        var state = UInt32(seed) &* 2_654_435_761 &+ 1
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return Data(bytes)
    }

    static func chunkName(_ index: Int) -> String {
        let id = UUID(uuidString: String(format: "6F9619FF-8B86-D011-B42D-%012X", index))!
        return CaptureNaming.chunkName(startedAt: baseDate.addingTimeInterval(Double(index) * 900), id: id, timeZone: utc)
    }

    static let noteName = "personal-capture-note-6f9619ff-8b86-d011-b42d-00c04fc964ff.m4a"
    static let draftNoteName = "personal-capture-note-draft-6f9619ff-8b86-d011-b42d-00c04fc964ff.m4a"

    @discardableResult
    static func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(component: name)
        try data.write(to: url)
        return url
    }
}
