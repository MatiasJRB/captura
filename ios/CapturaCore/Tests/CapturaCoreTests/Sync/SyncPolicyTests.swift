import XCTest
@testable import CapturaCore

/// Mirrors `SyncTests.automaticNeverUsesCellular`, `manualCanUseCellularButExpires`
/// and `receiptNeedsAllEvidence` from the Android suite.
final class SyncPolicyTests: XCTestCase {
    private let requested = Date(timeIntervalSince1970: 1_000)

    // MARK: allowed

    func testAutomaticSyncNeverUsesCellular() {
        XCTAssertFalse(SyncPolicy.allowed(manual: false, wifi: false, online: true, requestedAt: requested, now: requested))
    }

    func testAutomaticSyncUsesWiFi() {
        XCTAssertTrue(SyncPolicy.allowed(manual: false, wifi: true, online: true, requestedAt: requested, now: requested))
    }

    func testAutomaticSyncNeedsValidatedInternet() {
        XCTAssertFalse(SyncPolicy.allowed(manual: false, wifi: true, online: false, requestedAt: requested, now: requested))
    }

    func testManualSyncCanUseCellularInsideWindow() {
        let now = requested.addingTimeInterval(100)
        XCTAssertTrue(SyncPolicy.allowed(manual: true, wifi: false, online: true, requestedAt: requested, now: now))
    }

    func testManualWindowStillAllowsAtExactlyThirtyMinutes() {
        let now = requested.addingTimeInterval(30 * 60)
        XCTAssertTrue(SyncPolicy.allowed(manual: true, wifi: false, online: true, requestedAt: requested, now: now))
    }

    func testManualWindowExpiresOneMillisecondAfterThirtyMinutes() {
        let now = requested.addingTimeInterval(30 * 60 + 0.001)
        XCTAssertFalse(SyncPolicy.allowed(manual: true, wifi: false, online: true, requestedAt: requested, now: now))
    }

    func testExpiredManualRequestIsRefusedEvenOnWiFi() {
        let now = requested.addingTimeInterval(31 * 60)
        XCTAssertFalse(SyncPolicy.allowed(manual: true, wifi: true, online: true, requestedAt: requested, now: now))
    }

    func testManualRequestDatedInTheFutureIsRefused() {
        let now = requested.addingTimeInterval(-1)
        XCTAssertFalse(SyncPolicy.allowed(manual: true, wifi: false, online: true, requestedAt: requested, now: now))
    }

    func testManualSyncNeedsValidatedInternet() {
        let now = requested.addingTimeInterval(100)
        XCTAssertFalse(SyncPolicy.allowed(manual: true, wifi: true, online: false, requestedAt: requested, now: now))
    }

    func testManualWindowIsThirtyMinutes() {
        XCTAssertEqual(SyncPolicy.manualWindow, 1_800)
    }

    // MARK: verified

    private func verified(
        localBytes: Int64 = 40, localMD5: String? = "md5", localSHA: String? = "sha",
        remoteBytes: Int64 = 40, remoteMD5: String? = "md5", remoteSHA: String? = "sha", parent: Bool = true
    ) -> Bool {
        SyncPolicy.verified(
            localBytes: localBytes, localMD5: localMD5, localSHA: localSHA,
            remoteBytes: remoteBytes, remoteMD5: remoteMD5, remoteSHA: remoteSHA, correctParent: parent
        )
    }

    func testReceiptWithAllEvidenceIsVerified() {
        XCTAssertTrue(verified())
    }

    func testReceiptWithDifferentSizeIsNotVerified() {
        XCTAssertFalse(verified(remoteBytes: 41))
    }

    func testReceiptWithDifferentMD5IsNotVerified() {
        XCTAssertFalse(verified(remoteMD5: "wrong"))
    }

    func testReceiptWithDifferentSHAIsNotVerified() {
        XCTAssertFalse(verified(remoteSHA: "wrong"))
    }

    func testReceiptInAnotherFolderIsNotVerified() {
        XCTAssertFalse(verified(parent: false))
    }

    func testEmptyFileIsNeverVerified() {
        XCTAssertFalse(verified(localBytes: 0, remoteBytes: 0))
    }

    func testMissingLocalHashIsNeverVerified() {
        XCTAssertFalse(verified(localMD5: nil, remoteMD5: nil))
        XCTAssertFalse(verified(localSHA: nil, remoteSHA: nil))
    }

    func testMissingRemoteHashIsNotVerified() {
        XCTAssertFalse(verified(remoteMD5: nil))
    }
}
