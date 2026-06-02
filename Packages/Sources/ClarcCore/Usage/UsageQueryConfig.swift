import Foundation

/// Immutable request configuration passed to a `UsageAdapter`. Built on
/// every fetch from `AppState` UserDefaults + provider defaults — never
/// cached.
public struct UsageQueryConfig: Sendable, Equatable {
    public let provider: UsageProvider
    public let endpoint: String?
    public let bearerToken: String?
    public let fiveHourPath: String?
    public let sevenDayPath: String?

    public init(
        provider: UsageProvider,
        endpoint: String?,
        bearerToken: String? = nil,
        fiveHourPath: String? = nil,
        sevenDayPath: String? = nil
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.fiveHourPath = fiveHourPath
        self.sevenDayPath = sevenDayPath
    }
}
