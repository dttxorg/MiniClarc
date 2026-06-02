import Foundation

/// Identifies which provider implementation to use for fetching rate-limit
/// usage data. Each case carries the provider's default endpoint and JSON
/// path expressions; user-typed overrides live in `AppState` UserDefaults
/// keys and are merged at fetch time.
public enum UsageProvider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case minimax
    case openai
    case custom

    /// Built-in endpoint for this provider. `nil` means the user must
    /// supply one (OpenAI, Custom). Anthropic and MiniMax have
    /// well-known canonical URLs.
    public var defaultEndpoint: String? {
        switch self {
        case .anthropic: return "https://api.anthropic.com/api/oauth/usage"
        // The www.minimaxi.com host is a public marketing / management
        // CDN that does not host the API gateway. The real Token Plan
        // endpoint lives on the api subdomain — see diagnostic output
        // (DNS resolves www to a front-end Aliyun cluster that returns
        // "404 page not found" for this path; api resolves to the
        // openplatform-api server which returns the model_remains
        // JSON payload).
        case .minimax:   return "https://api.minimaxi.com/v1/token_plan/remains"
        case .openai:    return nil
        case .custom:    return nil
        }
    }

    /// Default dotted JSON path to the 5h utilization number, or `nil`
    /// when the provider parses the response internally (MiniMax) or
    /// when the user is expected to supply the path (Custom).
    public var defaultFiveHourPath: String? {
        switch self {
        case .anthropic: return "five_hour.utilization"
        case .minimax:   return nil
        case .openai:    return "five_hour.utilization"
        case .custom:    return nil
        }
    }

    /// Default dotted JSON path to the 7d utilization number. See
    /// `defaultFiveHourPath` for the `nil` cases.
    public var defaultSevenDayPath: String? {
        switch self {
        case .anthropic: return "seven_day.utilization"
        case .minimax:   return nil
        case .openai:    return "seven_day.utilization"
        case .custom:    return nil
        }
    }
}
