import Foundation
import Testing
@testable import ClarcCore

@Suite("UsageProvider")
struct UsageProviderTests {

    @Test("Raw value round-trips through Codable")
    func codableRoundTrip() throws {
        for p in UsageProvider.allCases {
            let data = try JSONEncoder().encode(p)
            let decoded = try JSONDecoder().decode(UsageProvider.self, from: data)
            #expect(decoded == p)
        }
    }

    @Test("Anthropic default endpoint is the oauth/usage URL")
    func anthropicEndpoint() {
        #expect(UsageProvider.anthropic.defaultEndpoint == "https://api.anthropic.com/api/oauth/usage")
    }

    @Test("Anthropic default paths are five_hour.utilization and seven_day.utilization")
    func anthropicPaths() {
        #expect(UsageProvider.anthropic.defaultFiveHourPath == "five_hour.utilization")
        #expect(UsageProvider.anthropic.defaultSevenDayPath == "seven_day.utilization")
    }

    @Test("MiniMax default endpoint is the official token_plan/remains URL")
    func minimaxEndpoint() {
        #expect(UsageProvider.minimax.defaultEndpoint == "https://www.minimaxi.com/v1/token_plan/remains")
    }

    @Test("MiniMax path defaults are nil — adapter parses internally")
    func minimaxPaths() {
        #expect(UsageProvider.minimax.defaultFiveHourPath == nil)
        #expect(UsageProvider.minimax.defaultSevenDayPath == nil)
    }

    @Test("MiniMax endpoint host is the verified www host, not the unverified api host")
    func minimaxEndpointHost() {
        // Guard against regressing into the api-subdomain hypothesis
        // (see UsageProvider.swift comment). The api host happened to
        // work in our reproduction too, but www is the host the user
        // validated against and that we are migrating to.
        guard let url = URL(string: UsageProvider.minimax.defaultEndpoint ?? "") else {
            Issue.record("MiniMax default endpoint is not a valid URL")
            return
        }
        #expect(url.host == "www.minimaxi.com")
    }

    @Test("OpenAI and Custom have empty defaults — user fills them in")
    func openaiAndCustomDefaults() {
        #expect(UsageProvider.openai.defaultEndpoint == nil)
        #expect(UsageProvider.custom.defaultEndpoint == nil)
        #expect(UsageProvider.openai.defaultFiveHourPath == "five_hour.utilization")
        #expect(UsageProvider.custom.defaultFiveHourPath == nil)
    }
}
