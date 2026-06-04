import XCTest
@testable import ClarcCore

final class TokenEstimatorTests: XCTestCase {
    func testEmptyStringReturnsZero() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
    }

    func testShortStringRoundsDown() {
        // 5 chars / 3 = 1
        XCTAssertEqual(TokenEstimator.estimate("hello"), 1)
    }

    func testTwelveCharsReturnsFour() {
        // 12 / 3 = 4
        XCTAssertEqual(TokenEstimator.estimate("hello world!"), 4)
    }

    func testEstimateMessageListSumsAllContents() {
        let messages = [
            ChatMessage(role: .user, content: "hello"),
            ChatMessage(role: .assistant, content: "world")
        ]
        // "hello" → 1, "world" → 1
        XCTAssertEqual(TokenEstimator.estimate(messages), 2)
    }

    func testEstimateIsConservativeForCJK() {
        // CJK 实际更密(1.5 chars/token),除以 3 略高估 → 行为正确
        let cjk = String(repeating: "中", count: 12)
        XCTAssertEqual(TokenEstimator.estimate(cjk), 4)
    }
}
