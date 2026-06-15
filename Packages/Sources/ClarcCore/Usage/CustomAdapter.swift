import Foundation

/// Adapter for user-typed endpoints. Looks up two numeric values via
/// `JSONPath` expressions, defaulting to the provider's built-in
/// expressions when the user leaves them blank. Does not parse reset
/// times — the path is for the utilization number only.
public struct CustomAdapter: UsageAdapter {

    public init() {}

    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        let urlString = config.endpoint ?? ""
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        if let token = config.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.http(status: -1, body: data)
        }
        guard http.statusCode == 200 else {
            throw UsageError.http(status: http.statusCode, body: data)
        }
        return try Self.parseResponse(
            data: data,
            httpStatus: 200,
            endpointURL: urlString,
            fiveHourPath: config.fiveHourPath,
            sevenDayPath: config.sevenDayPath
        )
    }

    /// Pure parser, exposed for tests.
    public static func parseResponse(
        data: Data,
        httpStatus: Int,
        endpointURL: String,
        fiveHourPath: String?,
        sevenDayPath: String?
    ) throws -> UsageFetchOutcome {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            throw UsageError.malformedJSON
        }
        let root = JSONValue(any: raw)

        let fivePath = fiveHourPath ?? UsageProvider.custom.defaultFiveHourPath
        let sevenPath = sevenDayPath ?? UsageProvider.custom.defaultSevenDayPath

        // For Custom, default path is nil — so we require user to provide.
        guard let fivePath else { throw UsageError.missingField("fiveHourPath") }
        guard let sevenPath else { throw UsageError.missingField("sevenDayPath") }

        let fiveParsed: JSONPath
        let sevenParsed: JSONPath
        do {
            fiveParsed = try JSONPathParser.parse(fivePath)
            sevenParsed = try JSONPathParser.parse(sevenPath)
        } catch {
            throw UsageError.missingField(fivePath)
        }

        guard let fiveLeaf = fiveParsed.lookup(in: root), let fiveValue = numericValue(at: fiveLeaf) else {
            throw UsageError.missingField(fivePath)
        }
        guard let sevenLeaf = sevenParsed.lookup(in: root), let sevenValue = numericValue(at: sevenLeaf) else {
            throw UsageError.missingField(sevenPath)
        }

        let usage = RateLimitUsage(
            fiveHourPercent: fiveValue,
            sevenDayPercent: sevenValue,
            fiveHourResetsAt: nil,
            sevenDayResetsAt: nil
        )
        return UsageFetchOutcome(usage: usage, rawJSON: data, httpStatus: httpStatus, endpointURL: endpointURL)
    }

    private static func numericValue(at v: JSONValue?) -> Double? {
        guard let v else { return nil }
        return v.numberValue
    }
}
