import Foundation

public struct MiniMaxAdapter: UsageAdapter {
    public init() {}
    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        throw UsageError.invalidURL
    }
}
