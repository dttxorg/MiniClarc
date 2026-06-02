import Foundation

/// Adapter for the Anthropic oauth/usage endpoint. Sends the
/// `anthropic-beta: oauth-2025-04-20` header required by Anthropic's
/// OAuth-protected APIs. Token preparation is the caller's job — this
/// adapter only consumes whatever bearer the config carries.
public struct AnthropicAdapter: UsageAdapter {

    public init() {}

    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        let urlString = config.endpoint ?? UsageProvider.anthropic.defaultEndpoint!
        guard let url = URL(string: urlString) else { throw UsageError.invalidURL }

        var request = URLRequest(url: url)
        if let token = config.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.http(status: -1, body: data)
        }
        guard http.statusCode == 200 else {
            throw UsageError.http(status: http.statusCode, body: data)
        }
        return try Self.parseResponse(data: data, httpStatus: 200, endpointURL: urlString)
    }

    /// Pure parser, exposed for tests. Throws `UsageError.malformedJSON`
    /// when the body is not a JSON object, or `UsageError.missingField`
    /// when utilization numbers are absent.
    public static func parseResponse(
        data: Data,
        httpStatus: Int,
        endpointURL: String
    ) throws -> UsageFetchOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformedJSON
        }

        guard let fiveHour = Self.numericValue(json["five_hour"] as? [String: Any], key: "utilization") else {
            throw UsageError.missingField("five_hour.utilization")
        }
        guard let sevenDay = Self.numericValue(json["seven_day"] as? [String: Any], key: "utilization") else {
            throw UsageError.missingField("seven_day.utilization")
        }
        let fiveHourResetsAt = Self.parseISO8601((json["five_hour"] as? [String: Any])?["resets_at"] as? String)
        let sevenDayResetsAt = Self.parseISO8601((json["seven_day"] as? [String: Any])?["resets_at"] as? String)

        let usage = RateLimitUsage(
            fiveHourPercent: fiveHour,
            sevenDayPercent: sevenDay,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayResetsAt: sevenDayResetsAt
        )
        return UsageFetchOutcome(usage: usage, rawJSON: data, httpStatus: httpStatus, endpointURL: endpointURL)
    }

    private static func numericValue(_ dict: [String: Any]?, key: String) -> Double? {
        guard let v = dict?[key] else { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func parseISO8601(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: s)
    }
}
