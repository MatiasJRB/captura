import Foundation
import XCTest
@testable import Captura

#if DEBUG
final class LaunchOptionsTests: XCTestCase {
    func testParsesBothAutomationFlags() {
        let options = LaunchOptions.parse(["Captura", "-CapturaAutoRecordSeconds", "6", "-CapturaChunkSeconds", "3"])
        XCTAssertEqual(options, LaunchOptions(autoRecordSeconds: 6, chunkSeconds: 3))
    }

    func testNoFlagsMeansNormalLaunch() {
        XCTAssertEqual(LaunchOptions.parse(["Captura"]), LaunchOptions())
    }

    func testInvalidOrOutOfRangeValuesAreIgnored() {
        XCTAssertNil(LaunchOptions.parse(["-CapturaAutoRecordSeconds", "abc"]).autoRecordSeconds)
        XCTAssertNil(LaunchOptions.parse(["-CapturaAutoRecordSeconds", "0"]).autoRecordSeconds)
        XCTAssertNil(LaunchOptions.parse(["-CapturaAutoRecordSeconds"]).autoRecordSeconds)
        XCTAssertNil(LaunchOptions.parse(["-CapturaChunkSeconds", "1"]).chunkSeconds)
        XCTAssertNil(LaunchOptions.parse(["-CapturaChunkSeconds", "nan"]).chunkSeconds)
        XCTAssertNil(LaunchOptions.parse(["-CapturaChunkSeconds", "3600"]).chunkSeconds)
    }

    func testTheTestHostIsLaunchedWithoutAutomation() {
        XCTAssertNil(LaunchOptions.current.autoRecordSeconds)
    }
}
#endif

final class RecordingRowTests: XCTestCase {
    func testStartDateComesFromTheChunkName() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let date = RecordingRow.startDate(fromChunkName: "personal-capture-20261006-174503-00000000-0000-4000-8000-000000000003.m4a", timeZone: utc)
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_791_308_703))
        XCTAssertNil(RecordingRow.startDate(fromChunkName: "notes.m4a"))
    }

    func testRowsAreNewestFirstWithIncompleteFilesLast() {
        let older = URL(fileURLWithPath: "/tmp/personal-capture-20261006-100000-00000000-0000-4000-8000-000000000004.m4a")
        let newer = URL(fileURLWithPath: "/tmp/personal-capture-20261006-110000-00000000-0000-4000-8000-000000000005.m4a")
        let partial = URL(fileURLWithPath: "/tmp/Quarantine/personal-capture-20261006-120000-00000000-0000-4000-8000-000000000006.m4a.partial")
        let rows = RecordingRow.build(closedChunks: [older, newer], items: [], quarantinedFiles: [partial])
        XCTAssertEqual(rows.map(\.fileName), [newer.lastPathComponent, older.lastPathComponent, partial.lastPathComponent])
        XCTAssertEqual(rows.map(\.status), [.localOnly, .localOnly, .incomplete])
    }
}
