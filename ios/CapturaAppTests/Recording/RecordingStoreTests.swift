import XCTest
@testable import Captura

final class RecordingStoreTests: XCTestCase {
    private let chunkName = "personal-capture-20261006-152000-6f9619ff-8b86-d011-b42d-00c04fc964ff.m4a"
    private var directory: URL!
    private var store: RecordingStore!

    override func setUpWithError() throws {
        directory = try RecorderFixtures.temporaryDirectory().appendingPathComponent("Recordings", isDirectory: true)
        store = RecordingStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func plant(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? directory).appendingPathComponent(name)
        try Data("fictional".utf8).write(to: url)
        return url
    }

    func testDefaultDirectoryIsApplicationSupportCapturaRecordings() {
        let path = RecordingStore.defaultDirectory.path
        XCTAssertTrue(path.hasSuffix("Library/Application Support/Captura/Recordings"), path)
    }

    func testPrepareCreatesRecordingsAndQuarantineFolders() throws {
        try store.prepare()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.quarantineDirectory.path))
    }

    func testPrepareExcludesRecordingsFromBackup() throws {
        try store.prepare()
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testPrepareKeepsRecordingsReadableWhileLocked() throws {
        try store.prepare()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard let protection = attributes[.protectionKey] as? FileProtectionType else {
            throw XCTSkip("This simulator does not report data protection classes")
        }
        XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
    }

    func testPrepareIsIdempotent() throws {
        try store.prepare()
        let chunk = try plant(chunkName)
        try store.prepare()
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path))
    }

    func testPartialURLIsChunkNamePlusPartialSuffix() {
        XCTAssertEqual(store.partialURL(forChunkNamed: chunkName).lastPathComponent, chunkName + ".partial")
        XCTAssertEqual(store.partialURL(forChunkNamed: chunkName).deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
    }

    func testFinalizeRenamesPartialToItsChunkName() throws {
        try store.prepare()
        let partial = try plant(chunkName + ".partial")
        let final = try store.finalize(partial: partial)
        XCTAssertEqual(final.lastPathComponent, chunkName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: final), Data("fictional".utf8))
    }

    func testFinalizeRefusesPartialThatIsNotARecorderChunk() throws {
        try store.prepare()
        let foreign = try plant("notes.txt.partial")
        XCTAssertThrowsError(try store.finalize(partial: foreign))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testQuarantineMovesFileKeepingItsName() throws {
        try store.prepare()
        let partial = try plant(chunkName + ".partial")
        let moved = try store.quarantine(partial)
        XCTAssertEqual(moved.lastPathComponent, chunkName + ".partial")
        XCTAssertEqual(moved.deletingLastPathComponent().standardizedFileURL, store.quarantineDirectory.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testQuarantineNeverOverwritesAnEarlierQuarantinedFile() throws {
        try store.prepare()
        _ = try store.quarantine(try plant(chunkName + ".partial"))
        let second = try store.quarantine(try plant(chunkName + ".partial"))
        XCTAssertEqual(store.quarantinedFiles().count, 2)
        XCTAssertNotEqual(second.lastPathComponent, chunkName + ".partial")
    }

    func testLeftoverPartialsAreQuarantinedAtLaunch() throws {
        try store.prepare()
        let partial = try plant(chunkName + ".partial")
        let recovered = store.quarantineLeftoverPartials()
        XCTAssertEqual(recovered.map(\.lastPathComponent), [partial.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(store.quarantinedFiles().map(\.lastPathComponent), [partial.lastPathComponent])
    }

    func testClosedChunksSurviveLaunchRecovery() throws {
        try store.prepare()
        let chunk = try plant(chunkName)
        _ = store.quarantineLeftoverPartials()
        XCTAssertEqual(store.closedChunks(), [chunk])
    }

    func testClosedChunksListsOnlyFinalChunkNamesSorted() throws {
        try store.prepare()
        let later = try plant("personal-capture-20261006-153000-00000000-0000-0000-0000-000000000002.m4a")
        let earlier = try plant("personal-capture-20261006-151500-00000000-0000-0000-0000-000000000001.m4a")
        _ = try plant(chunkName + ".partial")
        _ = try plant("voice-note.m4a")
        _ = try plant("personal-capture-20261006-140000-00000000-0000-0000-0000-000000000003.m4a", in: store.quarantineDirectory)
        XCTAssertEqual(store.closedChunks().map(\.lastPathComponent), [earlier.lastPathComponent, later.lastPathComponent])
    }
}
