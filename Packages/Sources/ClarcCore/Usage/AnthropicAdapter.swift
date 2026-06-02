import Foundation

public struct AnthropicAdapter: UsageAdapter {
    public init() {}
    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        throw UsageError.invalidURL
    }
}
