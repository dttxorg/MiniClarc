import Foundation
import Testing
@testable import ClarcCore

@Suite("AnthropicAdapter")
struct AnthropicAdapterTests {

    private let sample = """
    {
      "five_hour":  { "utilization": 23.0, "resets_at": "2026-06-02T18:00:00.000Z" },
      "seven_day":  { "utilization": 61.0, "resets_at": "2026-06-05T12:00:00Z" }
    }
    """.data(using: .utf8)!

    @Test("Parse sample response into RateLimitUsage with resets parsed")
    func parseSample() async throws {
        // We can't hit the real network from a unit test, so we drive
        // the private parser directly. The public fetch() does the same
        // thing after URLSession.
        let outcome = try await AnthropicAdapter.parseResponse(
            data: sample,
            httpStatus: 200,
            endpointURL: "https://api.anthropic.com/api/oauth/usage"
        )
        #expect(outcome.usage.fiveHourPercent == 23.0)
        #expect(outcome.usage.sevenDayPercent == 61.0)
        #expect(outcome.usage.fiveHourResetsAt != nil)
        #expect(outcome.usage.sevenDayResetsAt != nil)
        #expect(outcome.httpStatus == 200)
    }

    @Test("Missing resets_at is allowed — those fields are nil")
    func parseNoResets() async throws {
        let data = """
        { "five_hour": { "utilization": 5 }, "seven_day": { "utilization": 10 } }
        """.data(using: .utf8)!
        let outcome = try await AnthropicAdapter.parseResponse(
            data: data, httpStatus: 200, endpointURL: "x"
        )
        #expect(outcome.usage.fiveHourPercent == 5.0)
        #expect(outcome.usage.fiveHourResetsAt == nil)
        #expect(outcome.usage.sevenDayResetsAt == nil)
    }
}
