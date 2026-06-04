import XCTest
@testable import ClarcCore

final class CompactionRecordTests: XCTestCase {
    func testRecentUserBudgetIs20k() {
        XCTAssertEqual(CompactionRecord.recentUserTokenBudget, 20_000)
    }

    func testSummaryPrefixMentionsAnotherModel() {
        XCTAssertTrue(CompactionRecord.summaryPrefix.contains("Another language model"))
    }

    func testCompactionRecordIsCodable() throws {
        let messages = [
            ChatMessage(role: .user, content: "hi")
        ]
        let record = CompactionRecord(
            compactedAt: Date(timeIntervalSince1970: 1_000_000),
            summaryText: "summary content",
            originalMessages: messages,
            originalCount: 1,
            originalTokenEstimate: 1,
            newTokenEstimate: 2
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CompactionRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }
}
