import Foundation

/// Extracts "owner/repo" from a GitHub remote URL.
/// Supports HTTPS and SSH formats.
/// Returns nil for non-GitHub URLs.
public func parseGitHubOwnerRepo(from urlString: String) -> String? {
    // Reject obvious garbage early.
    guard !urlString.isEmpty else { return nil }

    // Normalize SSH form (git@github.com:owner/repo[.git]) into a parseable URL.
    let normalized: String
    if urlString.hasPrefix("git@github.com:") {
        let path = urlString.dropFirst("git@github.com:".count)
        normalized = "https://github.com/" + path
    } else {
        normalized = urlString
    }

    // Parse as URL; reject anything that is not a syntactically valid URL.
    guard var components = URLComponents(string: normalized) else { return nil }

    // Only consider the path — drop any query/fragment that could smuggle in
    // an "owner/repo" looking substring.
    components.query = nil
    components.fragment = nil
    let path = components.path

    // Host must be exactly github.com (case-insensitive). This rejects
    // evil.com/?ref=github.com/foo, notgithub.com.evil.com/... etc.
    guard let host = components.host, host.lowercased() == "github.com" else {
        return nil
    }

    // Split owner/repo from the path; strip only a single trailing .git suffix.
    let trimmed = path.hasSuffix(".git")
        ? String(path.dropLast(".git".count))
        : path
    let cleaned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    let parts = cleaned.split(separator: "/").map(String.init)
    guard parts.count >= 2 else { return nil }
    let owner = parts[0]
    let repo = parts[1]
    guard !owner.isEmpty, !repo.isEmpty else { return nil }
    return "\(owner)/\(repo)"
}
