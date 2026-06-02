import Foundation

/// "OpenAI" is a UX preset that aliases to `CustomAdapter` with
/// Anthropic-shaped default paths. The OpenAI admin `/v1/usage`
/// endpoint does not natively return a 5h/7d utilization shape; users
/// typically route it through a proxy that normalizes the response.
/// This adapter does not add a real OpenAI integration — it exists so
/// the Settings UI can offer "OpenAI" as a discoverable preset.
public struct OpenAIAdapter: UsageAdapter {

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

    public static func parseResponse(
        data: Data,
        httpStatus: Int,
        endpointURL: String,
        fiveHourPath: String?,
        sevenDayPath: String?
    ) throws -> UsageFetchOutcome {
        try CustomAdapter.parseResponse(
            data: data,
            httpStatus: httpStatus,
            endpointURL: endpointURL,
            fiveHourPath: fiveHourPath,
            sevenDayPath: sevenDayPath
        )
    }
}
