import Foundation
import XCTest
@testable import CapturaCore

final class WorkerFeedbackTests: XCTestCase {
    func report(state: String = "transcribed", quoteID: String = "example", text: String = "La prueba conserva los originales y permite volver atrás.") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "available": true, "generated_at": Date().timeIntervalSince1970 * 1000,
            "records": [["id": "example", "sha256": String(repeating: "a", count: 64), "state": state]],
            "highlights": ["schema_version": 1, "state": "ready", "generated_at": 2000,
                "topics": ["Migración de servidores"],
                "quotes": [["text": text, "id": quoteID, "sha256": String(repeating: "a", count: 64), "at": 1000, "start_ms": 9000]]]
        ])
    }
    func testReadsDirectTopicAndExactQuote() throws {
        let result = WorkerFeedback.parse(try report())
        XCTAssertEqual(result.topics.first, "Migración de servidores")
        XCTAssertEqual(result.quotes.first?.startMilliseconds, 9000)
        XCTAssertEqual(result.quotes.first?.text, "La prueba conserva los originales y permite volver atrás.")
        XCTAssertNotNil(result.generatedAt)
    }
    func testQuoteRequiresExactCommittedIdentity() throws {
        XCTAssertTrue(WorkerFeedback.parse(try report(state: "downloaded")).quotes.isEmpty)
        XCTAssertTrue(WorkerFeedback.parse(try report(quoteID: "different")).topics.isEmpty)
    }
    func testUnavailableOrUnsafeNeverFabricatesCompletionOrContent() throws {
        XCTAssertNil(WorkerFeedback.parse(Data("{}".utf8)).generatedAt)
        XCTAssertTrue(WorkerFeedback.parse(try report(text: "\u{202e}spoof")).quotes.isEmpty)
        XCTAssertTrue(WorkerFeedback.read(URL(fileURLWithPath: "/missing/example-feedback.json")).topics.isEmpty)
    }
}
