import Foundation
import ClarcCore
import os

actor RateLimitService {

    static let shared = RateLimitService()

    private let logger = Logger(subsystem: "com.claudework", category: "RateLimitService")

    private struct OAuthTokens {
        let accessToken: String
        let refreshToken: String?
        let rawOauth: [String: Any]
    }

    private var cached: RateLimitUsage?
    private var cachedAt: Date?
    private let cacheTTL: TimeInterval = 300  // 5 minutes
    private var authFailed = false

    /// Fetch current rate-limit usage.
    ///
    /// - Parameters:
    ///   - forceRefresh: bypass the 5-minute cache when true.
    ///   - customEndpoint: when non-nil, use this URL instead of the default
    ///     Anthropic oauth/usage endpoint. The custom URL's response must be
    ///     JSON compatible with Anthropic's payload (keys: `five_hour` and
    ///     `seven_day`, each with `utilization` (number 0-100) and optional
    ///     `resets_at` (ISO 8601 string)).
    ///   - customBearerToken: when `customEndpoint` is set, this token is sent
    ///     in the `Authorization: Bearer <token>` header. Ignored when
    ///     `customEndpoint` is nil (the default endpoint always uses the
    ///     OAuth access token read from Keychain).
    func fetchUsage(
        forceRefresh: Bool = false,
        customEndpoint: String? = nil,
        customBearerToken: String? = nil
    ) async -> RateLimitUsage? {
        if !forceRefresh, let c = cached, let at = cachedAt, Date().timeIntervalSince(at) < cacheTTL {
            return c
        }

        // Custom endpoint path: skip OAuth / Keychain entirely. The user
        // supplied their own URL and bearer; we just hit it.
        if let endpoint = customEndpoint, !endpoint.isEmpty {
            return await callAPI(
                token: customBearerToken ?? "",
                urlOverride: endpoint,
                isCustom: true
            )
        }

        if authFailed && !forceRefresh {
            return cached
        }

        guard let tokens = await readOAuthTokens() else {
            logger.debug("[RateLimit] OAuth token not found in Keychain")
            return cached
        }

        // If the token is expired, attempt to refresh it first
        let accessToken: String
        if isExpired(tokens.rawOauth) {
            logger.info("[RateLimit] Access token expired, attempting refresh...")
            if let refreshed = await refreshAccessToken(tokens) {
                accessToken = refreshed
            } else {
                logger.debug("[RateLimit] Token refresh failed, cannot fetch usage")
                authFailed = true
                return cached
            }
        } else {
            accessToken = tokens.accessToken
        }

        logger.info("[RateLimit] Token ready, calling API...")

        guard let usage = await callAPI(token: accessToken, urlOverride: nil, isCustom: false) else {
            logger.debug("[RateLimit] API call returned nil")
            return cached
        }
        logger.info("[RateLimit] 5h=\(usage.fiveHourPercent)% 7d=\(usage.sevenDayPercent)%")

        authFailed = false
        cached = usage
        cachedAt = Date()
        return usage
    }

    // MARK: - Keychain

    private func readOAuthTokens() async -> OAuthTokens? {
        guard let raw = await MainActor.run(body: { KeychainHelper.readString(service: "Claude Code-credentials") }) else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String
        else { return nil }

        let refreshToken = oauth["refreshToken"] as? String
        return OAuthTokens(accessToken: accessToken, refreshToken: refreshToken, rawOauth: oauth)
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
        // Consider expired 30 seconds before the actual expiry
        return Date() >= expiry.addingTimeInterval(-30)
    }

    // MARK: - Token Refresh

    private func refreshAccessToken(_ tokens: OAuthTokens) async -> String? {
        guard let refreshToken = tokens.refreshToken else {
            logger.debug("[RateLimit] No refresh token available")
            return nil
        }

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
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.debug("[RateLimit] Token refresh returned status \(code)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String
            else {
                logger.debug("[RateLimit] Token refresh response parse failed")
                return nil
            }

            logger.info("[RateLimit] Token refreshed successfully")
            // Skip Keychain write since account is unknown — use in-memory cache only
            return newAccessToken
        } catch {
            logger.debug("[RateLimit] Token refresh error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - API

    /// Hit either the default Anthropic oauth/usage endpoint or a user-supplied
    /// custom endpoint. The response schema is identical in both cases:
    /// `{ "five_hour": { "utilization": <0-100>, "resets_at": "..." },
    ///    "seven_day": { "utilization": <0-100>, "resets_at": "..." } }`
    ///
    /// - Parameters:
    ///   - token: bearer token. Required for the default endpoint (OAuth
    ///     access token); optional for custom endpoints (skipped if empty).
    ///   - urlOverride: when non-nil, use this URL instead of the default
    ///     Anthropic endpoint.
    ///   - isCustom: true when `urlOverride` is a user-supplied custom URL.
    ///     In that case we do not send the `anthropic-beta` header (which
    ///     is Anthropic-specific) and do not auth-fail on 401.
    private func callAPI(token: String, urlOverride: String?, isCustom: Bool) async -> RateLimitUsage? {
        let resolvedURL: String = urlOverride ?? "https://api.anthropic.com/api/oauth/usage"
        guard let url = URL(string: resolvedURL) else {
            logger.warning("[RateLimit] Invalid URL: \(resolvedURL, privacy: .public)")
            return nil
        }

        var request = URLRequest(url: url)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Only the default Anthropic endpoint understands the beta header.
        if !isCustom {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code == 401 && !isCustom {
                    logger.debug("[RateLimit] API returned 401 — token invalid")
                    authFailed = true
                } else {
                    logger.warning("[RateLimit] API returned status \(code) for \(isCustom ? "custom" : "default") endpoint")
                }
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("[RateLimit] Response is not a JSON object")
                return nil
            }

            let fiveHour = json["five_hour"] as? [String: Any]
            let sevenDay = json["seven_day"] as? [String: Any]

            return RateLimitUsage(
                fiveHourPercent: (fiveHour?["utilization"] as? Double) ?? 0,
                sevenDayPercent: (sevenDay?["utilization"] as? Double) ?? 0,
                fiveHourResetsAt: parseISO8601(fiveHour?["resets_at"] as? String),
                sevenDayResetsAt: parseISO8601(sevenDay?["resets_at"] as? String)
            )
        } catch {
            logger.error("Rate limit fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterFallback = ISO8601DateFormatter()

    private func parseISO8601(_ str: String?) -> Date? {
        guard let str else { return nil }
        return Self.isoFormatter.date(from: str) ?? Self.isoFormatterFallback.date(from: str)
    }
}
