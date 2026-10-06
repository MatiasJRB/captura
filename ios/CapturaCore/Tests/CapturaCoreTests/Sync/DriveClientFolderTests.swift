import XCTest
@testable import CapturaCore

final class DriveClientFolderTests: XCTestCase {
    private let device = Fixture.deviceID

    private func ensure(
        _ transport: ScriptedTransport, existing: String?, persisted: IDRecorder = IDRecorder()
    ) async throws -> DriveFolderResolution {
        try await makeClient(transport).ensureFolder(existingID: existing, deviceID: device) { id in
            persisted.record(id)
        }
    }

    func testCreatesFolderWithGeneratedIDWhenNoneIsStored() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.generate, status: 200, json: Drive.generatedIDs("newFolder1"))
        transport.on("POST", Drive.files, status: 200, json: #"{"id":"newFolder1"}"#)
        transport.on("GET", Drive.file("newFolder1"), status: 200, json: Drive.folderJSON(id: "newFolder1"))
        let persisted = IDRecorder()

        let result = try await ensure(transport, existing: nil, persisted: persisted)

        XCTAssertEqual(result, DriveFolderResolution(id: "newFolder1", outcome: .created))
        XCTAssertEqual(persisted.current, "newFolder1")
    }

    func testFolderCreationSendsAndroidMetadata() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.generate, status: 200, json: Drive.generatedIDs("newFolder1"))
        transport.on("POST", Drive.files, status: 200, json: #"{"id":"newFolder1"}"#)
        transport.on("GET", Drive.file("newFolder1"), status: 200, json: Drive.folderJSON(id: "newFolder1"))

        _ = try await ensure(transport, existing: nil)

        let create = transport.requests[1]
        XCTAssertEqual(create.url.absoluteString, "https://www.googleapis.com/drive/v3/files?fields=id")
        XCTAssertEqual(create.headers["Content-Type"], "application/json; charset=UTF-8")
        XCTAssertEqual(create.body, .data(DriveMetadata.folderJSON(id: "newFolder1", deviceID: device)))
    }

    func testNewFolderIDIsPersistedBeforeTheFolderIsCreated() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.generate, status: 200, json: Drive.generatedIDs("newFolder1"))
        transport.on("POST", Drive.files, status: 200, json: #"{"id":"newFolder1"}"#)
        transport.on("GET", Drive.file("newFolder1"), status: 200, json: Drive.folderJSON(id: "newFolder1"))
        let requestsAtPersist = IDRecorder()

        _ = try await makeClient(transport).ensureFolder(existingID: nil, deviceID: device) { _ in
            requestsAtPersist.record(String(transport.requests.count))
        }

        XCTAssertEqual(requestsAtPersist.current, "1", "only generateIds may run before the ID is saved")
    }

    func testFailedPersistenceCreatesNothing() async {
        struct DiskFull: Error {}
        let transport = ScriptedTransport()
        transport.on("GET", Drive.generate, status: 200, json: Drive.generatedIDs("newFolder1"))
        do {
            _ = try await makeClient(transport).ensureFolder(existingID: nil, deviceID: device) { _ in throw DiskFull() }
            XCTFail("a folder must not be created when its ID cannot be saved")
        } catch {
            XCTAssertTrue(error is DiskFull)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testValidStoredFolderIsReusedWithOneRequest() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("folder"), status: 200, json: Drive.folderJSON())

        let result = try await ensure(transport, existing: "folder")

        XCTAssertEqual(result, DriveFolderResolution(id: "folder", outcome: .reused))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testStoredFolderMissingInDriveIsCreatedWithTheSameID() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("folder"), status: 404)
        transport.on("POST", Drive.files, status: 200, json: #"{"id":"folder"}"#)
        transport.on("GET", Drive.file("folder"), status: 200, json: Drive.folderJSON())

        let result = try await ensure(transport, existing: "folder")

        XCTAssertEqual(result, DriveFolderResolution(id: "folder", outcome: .created))
        XCTAssertEqual(transport.requests[1].body, .data(DriveMetadata.folderJSON(id: "folder", deviceID: device)))
    }

    func testConflictOnCreationIsAcceptedWhenTheFolderIsValid() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("folder"), status: 404)
        transport.on("POST", Drive.files, status: 409)
        transport.on("GET", Drive.file("folder"), status: 200, json: Drive.folderJSON())

        let result = try await ensure(transport, existing: "folder")

        XCTAssertEqual(result, DriveFolderResolution(id: "folder", outcome: .created))
    }

    func testTrashedFolderIsReplacedByANewOne() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("folder"), status: 200, json: Drive.folderJSON(trashed: true))
        transport.on("GET", Drive.generate, status: 200, json: Drive.generatedIDs("newFolder2"))
        transport.on("POST", Drive.files, status: 200, json: #"{"id":"newFolder2"}"#)
        transport.on("GET", Drive.file("newFolder2"), status: 200, json: Drive.folderJSON(id: "newFolder2"))
        let persisted = IDRecorder("folder")

        let result = try await ensure(transport, existing: "folder", persisted: persisted)

        XCTAssertEqual(result, DriveFolderResolution(id: "newFolder2", outcome: .replaced(previousID: "folder")))
        XCTAssertEqual(persisted.current, "newFolder2")
    }

    func testFolderOfAnotherDeviceIsReplaced() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("folder"), status: 200, json: Drive.folderJSON(device: "other-device"))
        transport.on("GET", Drive.generate, status: 200, json: Drive.generatedIDs("newFolder2"))
        transport.on("POST", Drive.files, status: 200, json: #"{"id":"newFolder2"}"#)
        transport.on("GET", Drive.file("newFolder2"), status: 200, json: Drive.folderJSON(id: "newFolder2"))

        let result = try await ensure(transport, existing: "folder")

        XCTAssertEqual(result.outcome, .replaced(previousID: "folder"))
    }

    func testFolderWithoutInboxMarkerIsReplaced() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("folder"), status: 200, json: Drive.folderJSON(inbox: "0"))
        transport.on("GET", Drive.generate, status: 200, json: Drive.generatedIDs("newFolder2"))
        transport.on("POST", Drive.files, status: 200, json: #"{"id":"newFolder2"}"#)
        transport.on("GET", Drive.file("newFolder2"), status: 200, json: Drive.folderJSON(id: "newFolder2"))

        let result = try await ensure(transport, existing: "folder")

        XCTAssertEqual(result.outcome, .replaced(previousID: "folder"))
    }

    func testStoredIDThatIsNotAFolderIsReplaced() async throws {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("folder"), status: 200, json: Drive.folderJSON(mimeType: "audio/mp4"))
        transport.on("GET", Drive.generate, status: 200, json: Drive.generatedIDs("newFolder2"))
        transport.on("POST", Drive.files, status: 200, json: #"{"id":"newFolder2"}"#)
        transport.on("GET", Drive.file("newFolder2"), status: 200, json: Drive.folderJSON(id: "newFolder2"))

        let result = try await ensure(transport, existing: "folder")

        XCTAssertEqual(result.outcome, .replaced(previousID: "folder"))
    }

    /// Mirrors `SyncTests.refusesSharedFolder`.
    func testSharedFolderIsRefusedWithoutCreatingAnything() async {
        let transport = ScriptedTransport()
        transport.on(
            "GET", Drive.file("folder"), status: 200,
            json: #"{"mimeType":"application/vnd.google-apps.folder","shared":true,"ownedByMe":true,"properties":{"device":"test-device"}}"#
        )
        do {
            _ = try await ensure(transport, existing: "folder")
            XCTFail("a shared inbox must be refused")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidPrivateFolder)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testFolderOwnedBySomeoneElseIsRefused() async {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.file("folder"), status: 200, json: Drive.folderJSON(ownedByMe: false))
        do {
            _ = try await ensure(transport, existing: "folder")
            XCTFail("a folder owned by someone else must be refused")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidPrivateFolder)
        }
    }

    func testFreshFolderThatComesBackSharedIsRefused() async {
        let transport = ScriptedTransport()
        transport.on("GET", Drive.generate, status: 200, json: Drive.generatedIDs("newFolder1"))
        transport.on("POST", Drive.files, status: 200, json: #"{"id":"newFolder1"}"#)
        transport.on("GET", Drive.file("newFolder1"), status: 200, json: Drive.folderJSON(id: "newFolder1", shared: true))
        do {
            _ = try await ensure(transport, existing: nil)
            XCTFail("an unverifiable new folder must be refused")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidPrivateFolder)
        }
    }

    func testInvalidDeviceIDIsRefusedWithoutRequests() async {
        let transport = ScriptedTransport()
        do {
            _ = try await makeClient(transport).ensureFolder(existingID: "folder", deviceID: "") { _ in }
            XCTFail("an empty device ID must be refused")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidDeviceID)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testMalformedStoredFolderIDIsRefusedWithoutRequests() async {
        let transport = ScriptedTransport()
        do {
            _ = try await ensure(transport, existing: "../folder")
            XCTFail("a malformed folder ID must be refused")
        } catch {
            XCTAssertEqual(error as? DriveError, .invalidIdentifier)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
