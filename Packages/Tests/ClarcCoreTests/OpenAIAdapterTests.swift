import Foundation
import Testing
@testable import ClarcCore

@Suite("OpenAIAdapter")
struct OpenAIAdapterTests {

    @Test("OpenAI provider with default Anthropic-shaped paths parses proxy response")
    func defaultPaths() throws {
        let data = #"{"five_hour": {"utilization": 7}, "seven_day": {"utilization": 14}}"#.data(using: .utf8)!
        let outcome = try OpenAIAdapter.parseResponse(
            data: data, httpStatus: 200, endpointURL: "x",
            fiveHourPath: "five_hour.utilization",
            sevenDayPath: "seven_day.utilization"
        )
        #expect(outcome.usage.fiveHourPercent == 7)
        #expect(outcome.usage.sevenDayPercent == 14)
    }
}
