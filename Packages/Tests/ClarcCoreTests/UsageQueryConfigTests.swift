import Testing
@testable import ClarcCore

@Suite("UsageQueryConfig")
struct UsageQueryConfigTests {

    @Test("Init stores all fields")
    func initStores() {
        let cfg = UsageQueryConfig(
            provider: .minimax,
            endpoint: "https://example/usage",
            bearerToken: "tok",
            fiveHourPath: "a.b",
            sevenDayPath: "c.d"
        )
        #expect(cfg.provider == .minimax)
        #expect(cfg.endpoint == "https://example/usage")
        #expect(cfg.bearerToken == "tok")
        #expect(cfg.fiveHourPath == "a.b")
        #expect(cfg.sevenDayPath == "c.d")
    }

    @Test("Optional fields default to nil")
    func optionalDefaults() {
        let cfg = UsageQueryConfig(provider: .anthropic, endpoint: nil)
        #expect(cfg.bearerToken == nil)
        #expect(cfg.fiveHourPath == nil)
        #expect(cfg.sevenDayPath == nil)
    }
}
