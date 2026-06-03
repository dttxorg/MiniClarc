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
            guard let tokens = await readOAuthTokens() else {
                logger.debug("[RateLimit] OAuth token not found in Keychain")
                return cached
            }
            // If the stored token is expired, try to refresh. If refresh
            // fails, do NOT fall back to the expired token — using an
            // expired token guarantees a 401, which would just flip us
            // into the authFailed branch below. Instead, return nil/cached
            // and let the caller surface the auth problem.
            var resolvedToken: String? = tokens.accessToken
            if isExpired(tokens.rawOauth) {
                if let refreshed = await refreshAccessToken(tokens) {
                    resolvedToken = refreshed
                } else {
                    logger.error("[RateLimit] OAuth token expired and refresh failed; not calling API with stale token")
                    authFailed = true
                    return cached
                }
            }
            guard let token = resolvedToken else { return cached }
            config = UsageQueryConfig(
                provider: .anthropic,
                endpoint: endpoint,
                bearerToken: token,
                fiveHourPath: fiveHourPath,
                sevenDayPath: sevenDayPath
            )
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
            logger.error("[RateLimit] fetch failed: \(error.localizedDescription)")
            return cached
        }
    }

    // MARK: - Keychain (Anthropic only)

    /// Public so the GitHub login flow (or any flow that writes a new OAuth
    /// token) can reset the cached auth state. Without this, the user
    /// re-authorizes in the system keychain but `authFailed` from a prior
    /// 401 keeps them locked out of the usage display.
    func resetAuthFailure() {
        authFailed = false
    }

    private func readOAuthTokens() async -> OAuthTokens? {
        // KeychainHelper.readString is synchronous and can block for
        // hundreds of ms (it fork/execs `/usr/bin/security`). We offload
        // it to a global background queue so we don't sit on the actor's
        // cooperative thread pool. We deliberately do NOT use
        // `MainActor.run` here — that would put the blocking work back on
        // the main thread, where it would freeze the UI when the keychain
        // is locked.
        let keychainResult: String? = await Task.detached(priority: .userInitiated) {
            KeychainHelper.readString(service: "Claude Code-credentials")
        }.value
        guard let raw = keychainResult else { return nil }
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

            // Persist the new access token (and any rotated refresh token /
            // new expiresAt) back to the Keychain. Without this, every
            // process restart re-reads the stale, soon-to-expire token and
            // triggers a refresh on first use, wasting one RTT and creating
            // a window where the API call is made with an expired token.
            await persistRefreshedTokens(
                newAccessToken: newAccessToken,
                newRefreshToken: json["refresh_token"] as? String,
                expiresAt: json["expires_at"],
                existingRaw: tokens.rawOauth
            )

            return newAccessToken
        } catch {
            return nil
        }
    }

    /// Merge the new access token (and any rotated refresh token / new
    /// expiry) into the existing `claudeAiOauth` dict and write the
    /// updated JSON back to the Keychain. Failures are logged but
    /// non-fatal — the caller still gets a valid token for this request.
    private func persistRefreshedTokens(
        newAccessToken: String,
        newRefreshToken: String?,
        expiresAt: Any?,
        existingRaw: [String: Any]
    ) async {
        var updated = existingRaw
        updated["accessToken"] = newAccessToken
        if let newRefreshToken {
            updated["refreshToken"] = newRefreshToken
        }
        if let expiresAt {
            updated["expiresAt"] = expiresAt
        } else {
            // Anthropic's refresh response may not include expiresAt in
            // some shapes. Fall back to a 1-hour default from now so the
            // next fetch doesn't immediately try to refresh again.
            updated["expiresAt"] = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        }

        let wrapper: [String: Any] = ["claudeAiOauth": updated]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper, options: []) else { return }

        // Persist off the main thread — the helper calls `/usr/bin/security`
        // synchronously and may prompt the user.
        let didPersist = await Task.detached(priority: .utility) {
            (try? KeychainHelper.save(data, service: "Claude Code-credentials")) != nil
        }.value
        if !didPersist {
            logger.error("[RateLimit] Failed to persist refreshed OAuth token to Keychain")
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterFallback = ISO8601DateFormatter()
}
