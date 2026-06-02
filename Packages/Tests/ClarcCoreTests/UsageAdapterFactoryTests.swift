import Testing
@testable import ClarcCore

@Suite("UsageAdapterFactory")
struct UsageAdapterFactoryTests {

    @Test("Anthropic returns AnthropicAdapter")
    func anthropic() {
        let a = UsageAdapterFactory.make(provider: .anthropic)
        #expect(type(of: a) == AnthropicAdapter.self)
    }

    @Test("MiniMax returns MiniMaxAdapter")
    func minimax() {
        let a = UsageAdapterFactory.make(provider: .minimax)
        #expect(type(of: a) == MiniMaxAdapter.self)
    }

    @Test("OpenAI returns OpenAIAdapter")
    func openai() {
        let a = UsageAdapterFactory.make(provider: .openai)
        #expect(type(of: a) == OpenAIAdapter.self)
    }

    @Test("Custom returns CustomAdapter")
    func custom() {
        let a = UsageAdapterFactory.make(provider: .custom)
        #expect(type(of: a) == CustomAdapter.self)
    }
}
