import Foundation
import ClarcCore
import os

/// Fetches the marketplace catalog from Anthropic's GitHub repositories
/// and handles plugin installation/uninstallation via Claude Code CLI.
actor MarketplaceService {

    private let logger = Logger(subsystem: "com.claudework", category: "MarketplaceService")

    /// Cached catalog with TTL.
    private var cachedCatalog: [MarketplacePlugin] = []
    private var cacheDate: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    /// Source repositories to scan.
    private static let sourceRepos: [(owner: String, repo: String, defaultCategory: String)] = [
        ("anthropics", "claude-plugins-official", "official"),
        ("anthropics", "skills", "agent-skills"),
        ("anthropics", "knowledge-work-plugins", "knowledge-work"),
        ("anthropics", "financial-services-plugins", "financial-services"),
    ]

    // MARK: - Fetch Catalog

    func fetchCatalog(forceRefresh: Bool = false) async -> [MarketplacePlugin] {
        if !forceRefresh,
           let cacheDate,
           Date().timeIntervalSince(cacheDate) < cacheTTL,
           !cachedCatalog.isEmpty {
            return cachedCatalog
        }

        var allPlugins: [MarketplacePlugin] = []

        await withTaskGroup(of: [MarketplacePlugin].self) { group in
            for source in Self.sourceRepos {
                group.addTask {
                    await self.fetchRepoPlugins(
                        owner: source.owner,
                        repo: source.repo,
                        defaultCategory: source.defaultCategory
                    )
                }
            }
            for await plugins in group {
                allPlugins.append(contentsOf: plugins)
            }
        }

        allPlugins.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        cachedCatalog = allPlugins
        cacheDate = Date()

        logger.info("Fetched \(allPlugins.count) plugins from marketplace")
        return allPlugins
    }

    // MARK: - Fetch Repository

    private func fetchRepoPlugins(owner: String, repo: String, defaultCategory: String) async -> [MarketplacePlugin] {
        let catalogURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/main/.claude-plugin/marketplace.json"
        guard let url = URL(string: catalogURL) else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }
            return parseMarketplaceCatalog(data: data, owner: owner, repo: repo, defaultCategory: defaultCategory)
        } catch {
            logger.warning("Failed to fetch catalog from \(owner)/\(repo): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Parse Catalog

    private func parseMarketplaceCatalog(data: Data, owner: String, repo: String, defaultCategory: String) -> [MarketplacePlugin] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let marketplaceName = json["name"] as? String,
              let plugins = json["plugins"] as? [[String: Any]] else {
            return []
        }

        let ownerInfo = json["owner"] as? [String: Any]
        let defaultAuthor = ownerInfo?["name"] as? String ?? owner

        return plugins.compactMap { entry -> MarketplacePlugin? in
            guard let name = entry["name"] as? String else { return nil }

            let description = entry["description"] as? String ?? ""
            let category = entry["category"] as? String ?? defaultCategory
            let homepage = entry["homepage"] as? String ?? ""

            // author: string or { "name": "..." } object
            let author: String
            if let authorDict = entry["author"] as? [String: Any] {
                author = authorDict["name"] as? String ?? defaultAuthor
            } else if let authorStr = entry["author"] as? String {
                author = authorStr
            } else {
                author = defaultAuthor
            }

            // Parse source: string (local path) or object (url/git-subdir)
            let sourceType: MarketplacePlugin.SourceType
            let skillPaths: [String]

            if let skills = entry["skills"] as? [String], !skills.isEmpty {
                // skills repository: bundle format
                sourceType = .skillsBundle
                skillPaths = skills
            } else if let sourceDict = entry["source"] as? [String: Any] {
                // Object form: {"source": "url", "url": "..."} or {"source": "git-subdir", ...}
                let sourceStr = sourceDict["source"] as? String ?? "url"
                sourceType = MarketplacePlugin.SourceType(rawValue: sourceStr) ?? .url
                skillPaths = []
            } else {
                // String form: local path such as "./plugins/name"
                sourceType = .local
                skillPaths = []
            }

            return MarketplacePlugin(
                name: name,
                description: description,
                author: author,
                category: category,
                homepage: homepage,
                marketplace: marketplaceName,
                sourceType: sourceType,
                skillPaths: skillPaths
            )
        }
    }

    // MARK: - Installation (via Claude Code CLI)

    /// Retrieve the set of installed plugin names from `~/.claude/plugins/installed_plugins.json`.
    ///
    /// The on-disk format (Claude Code v2.x) is:
    /// ```json
    /// {
    ///   "version": 2,
    ///   "plugins": {
    ///     "<plugin>@<marketplace>": [
    ///       { "scope": "user", "version": "x.y.z", "installedAt": "...", ... }
    ///     ]
    ///   }
    /// }
    /// ```
    /// Keys are `"<name>@<marketplace>"` — the exact same form that
    /// `claude plugin install <name>@<marketplace>` takes. We strip the
    /// `@<marketplace>` suffix so the UI matches by plugin name alone.
    func installedPluginNames() async -> Set<String> {
        let names = installedPluginNamesFromDisk()
        if !names.isEmpty { return names }
        return await installedPluginNamesFromCLI()
    }

    private func installedPluginNamesFromCLI() async -> Set<String> {
        let (output, exitCode) = await runCLI(["plugin", "list"])
        guard exitCode == 0 else { return [] }
        // Output is plain text, one plugin per line. Plugin name may or may
        // not have a `@<marketplace>` suffix depending on the CLI version.
        return Set(
            output.split(whereSeparator: { $0.isNewline || $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
                .map { $0.contains("@") ? String($0.split(separator: "@").first ?? Substring($0)) : $0 }
        )
    }

    private func installedPluginNamesFromDisk() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fileURL = URL(fileURLWithPath: "\(home)/.claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: [Any]] else {
            // Fallback: list subdirectories of the known plugin roots.
            return installedPluginNamesFromDirectoryScan()
        }
        // Keys are "<name>@<marketplace>"; strip the suffix.
        return Set(plugins.keys.compactMap { key in
            key.split(separator: "@").first.map(String.init)
        })
    }

    private func installedPluginNamesFromDirectoryScan() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        var names: Set<String> = []
        for dir in ["\(home)/.claude/plugins", "\(home)/.claude/skills"] {
            if let entries = try? fm.contentsOfDirectory(atPath: dir) {
                for entry in entries where !entry.hasPrefix(".") {
                    // Strip the @<marketplace> suffix if present.
                    let name = entry.split(separator: "@").first.map(String.init) ?? entry
                    names.insert(name)
                }
            }
        }
        return names
    }

    /// Install a plugin by running `claude plugin install <name>@<marketplace>`
    func installPlugin(_ plugin: MarketplacePlugin) async throws {
        let installArg = "\(plugin.name)@\(plugin.marketplace)"
        let (_, exitCode) = await runCLI(["plugin", "install", installArg])
        guard exitCode == 0 else {
            throw MarketplaceError.installFailed(installArg)
        }
        logger.info("Installed plugin: \(plugin.name, privacy: .public) from \(plugin.marketplace, privacy: .public)")
    }

    /// Uninstall a plugin by running `claude plugin uninstall <name>`
    func uninstallPlugin(_ plugin: MarketplacePlugin) async throws {
        let (_, exitCode) = await runCLI(["plugin", "uninstall", plugin.name])
        guard exitCode == 0 else {
            throw MarketplaceError.uninstallFailed(plugin.name)
        }
        logger.info("Uninstalled plugin: \(plugin.name, privacy: .public)")
    }

    // MARK: - CLI Runner

    private func runCLI(_ arguments: [String], timeout: TimeInterval = 30) async -> (output: String, exitCode: Int32) {
        // We can't cancel a Process from inside a `withCheckedContinuation`
        // without leaking the continuation. Use an actor-isolated wrapper:
        // wrap the process in a class so we can reach it from the timeout
        // task to force-terminate.
        final class ProcessBox: @unchecked Sendable {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
        }

        let box = ProcessBox()

        return await withCheckedContinuation { (continuation: CheckedContinuation<(output: String, exitCode: Int32), Never>) in
            let stdoutPipe = box.stdoutPipe
            let stderrPipe = box.stderrPipe
            let process = box.process

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["claude"] + arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            // Inherit a safe subset of env; do not pass the parent env wholesale.
            process.environment = [
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
                "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            ]

            // IMPORTANT: keep a strong reference to `box` inside the closure
            // so the process isn't deallocated mid-run.
            let timeoutBox = box
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    // Force-kill so the continuation definitely resumes.
                    kill(process.processIdentifier, SIGKILL)
                }
                _ = timeoutBox  // retain
            }

            process.terminationHandler = { _ in
                timeoutTask.cancel()
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                let merged = err.isEmpty ? out : "\(out)\n\(err)"
                continuation.resume(returning: (merged, process.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                continuation.resume(returning: (error.localizedDescription, 1))
            }
        }
    }

    // MARK: - Errors

    enum MarketplaceError: LocalizedError {
        case installFailed(String)
        case uninstallFailed(String)

        var errorDescription: String? {
            switch self {
            case .installFailed(let name): return "Plugin installation failed: \(name)"
            case .uninstallFailed(let name): return "Plugin uninstallation failed: \(name)"
            }
        }
    }
}
