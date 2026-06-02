import Foundation

public struct CustomAdapter: UsageAdapter {
    public init() {}
    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        throw UsageError.invalidURL
    }
}
