import Foundation

/// Errors a `UsageAdapter` may surface to the caller.
public enum UsageError: Error, Sendable, Equatable {
    case invalidURL
    case http(status: Int, body: Data)
    case malformedJSON
    case missingField(String)
    case numericOutOfRange(field: String, value: Double)
}

/// Result of a successful `UsageAdapter.fetch` call. `usage` carries
/// the canonical 0-100 utilization values (already inverted if the
/// source shape uses "remaining"); `rawJSON` is the unparsed response
/// body, captured for the Test Endpoint debug sheet.
public struct UsageFetchOutcome: Sendable {
    public let usage: RateLimitUsage
    public let rawJSON: Data
    public let httpStatus: Int
    public let endpointURL: String

    public init(usage: RateLimitUsage, rawJSON: Data, httpStatus: Int, endpointURL: String) {
        self.usage = usage
        self.rawJSON = rawJSON
        self.httpStatus = httpStatus
        self.endpointURL = endpointURL
    }
}

/// Contract for a usage-data source. Implementations are stateless
/// aside from any HTTP session caching, and must be `Sendable` so the
/// `RateLimitService` actor can call them across isolation domains.
public protocol UsageAdapter: Sendable {
    func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome
}

/// Resolves the right adapter for a `UsageProvider`. Add new providers
/// by extending the switch and adding a new `UsageAdapter` conformance.
public enum UsageAdapterFactory {

    public static func make(provider: UsageProvider) -> any UsageAdapter {
        switch provider {
        case .anthropic: return AnthropicAdapter()
        case .minimax:   return MiniMaxAdapter()
        case .openai:    return OpenAIAdapter()
        case .custom:    return CustomAdapter()
        }
    }
}
