import Foundation

public struct OpenAIAdapter: UsageAdapter {
    public init() {}
    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        throw UsageError.invalidURL
    }
}
