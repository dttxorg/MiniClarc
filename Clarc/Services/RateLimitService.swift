import Foundation
import ClarcCore
import os

/// Coordinator for usage-data fetches. Reads the user's chosen
/// `UsageProvider` + endpoint/token/path overrides from the app's
/// persisted settings, resolves the OAuth access token for the
/// Anthropic path, hands the request to the appropriate
/// `UsageAdapter`, and caches the result for 5 minutes.
actor RateLimitService {

    static let shared = RateLimitService()

    private let logger = Logger(subsystem: "com.claudework", category: "RateLimitService")

    private struct OAuthTokens {
        let accessToken: String
        let rawOauth: [String: Any]
    }

    private var cached: RateLimitUsage?
    private var cachedAt: Date?
    private let cacheTTL: TimeInterval = 300
    private var authFailed = false

    /// Fetch the current usage. Cached for 5 minutes unless
    /// `forceRefresh` is true.
    func fetchUsage(
        forceRefresh: Bool = false,
        provider: UsageProvider = .anthropic,
        endpoint: String? = nil,
        bearerToken: String? = nil,
        fiveHourPath: String? = nil,
        sevenDayPath: String? = nil
    ) async -> RateLimitUsage? {
        if !forceRefresh, let c = cached, let at = cachedAt, Date().timeIntervalSince(at) < cacheTTL {
            return c
        }

        if authFailed && !forceRefresh {
            return cached
        }

        // Build the config; resolve the OAuth token only for Anthropic.
        var config = UsageQueryConfig(
            provider: provider,
            endpoint: endpoint,
            bearerToken: bearerToken,
            fiveHourPath: fiveHourPath,
            sevenDayPath: sevenDayPath
        )
        if provider == .anthropic {
            if let tokens = await readOAuthTokens() {
                let token = isExpired(tokens.rawOauth) ? (await refreshAccessToken(tokens) ?? tokens.accessToken) : tokens.accessToken
                config = UsageQueryConfig(
                    provider: .anthropic,
                    endpoint: endpoint,
                    bearerToken: token,
                    fiveHourPath: fiveHourPath,
                    sevenDayPath: sevenDayPath
                )
            } else {
                logger.debug("[RateLimit] OAuth token not found in Keychain")
                return cached
            }
        }

        do {
            let outcome = try await UsageAdapterFactory
                .make(provider: config.provider)
                .fetch(config: config)
            logger.info("[RateLimit] 5h=\(outcome.usage.fiveHourPercent)% 7d=\(outcome.usage.sevenDayPercent)%")
            cached = outcome.usage
            cachedAt = Date()
            authFailed = false
            return outcome.usage
        } catch UsageError.http(let status, _) where provider == .anthropic && status == 401 {
            logger.debug("[RateLimit] API returned 401 — token invalid")
            authFailed = true
            return cached
        } catch {
            logger.error("[RateLimit] fetch failed: \(String(describing: error))")
            return cached
        }
    }

    // MARK: - Keychain (Anthropic only)

    private func readOAuthTokens() async -> OAuthTokens? {
        guard let raw = await MainActor.run(body: { KeychainHelper.readString(service: "Claude Code-credentials") }) else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String
        else { return nil }
        return OAuthTokens(accessToken: accessToken, rawOauth: oauth)
    }

    private func isExpired(_ oauth: [String: Any]) -> Bool {
        guard let expiresAt = oauth["expiresAt"] else { return false }
        var expiryDate: Date?
        if let ms = expiresAt as? Double {
            let seconds = ms > 1e10 ? ms / 1000 : ms
            expiryDate = Date(timeIntervalSince1970: seconds)
        } else if let str = expiresAt as? String {
            expiryDate = Self.isoFormatter.date(from: str) ?? Self.isoFormatterFallback.date(from: str)
        }
        guard let expiry = expiryDate else { return false }
        return Date() >= expiry.addingTimeInterval(-30)
    }

    private func refreshAccessToken(_ tokens: OAuthTokens) async -> String? {
        guard let refreshToken = tokens.rawOauth["refreshToken"] as? String else { return nil }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/token") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String
            else { return nil }
            return newAccessToken
        } catch {
            return nil
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterFallback = ISO8601DateFormatter()
}
