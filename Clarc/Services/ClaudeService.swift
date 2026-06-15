// Modifications Copyright 2026 dttxorg (MiniClarc).
// SPDX-License-Identifier: Apache-2.0
//
// Originally: Clarc (https://github.com/ttnear/Clarc), Apache License 2.0.
// See ../../NOTICE in the repository root for the full modification history.

import Foundation
import ClarcCore
import os

// MARK: - ClaudeService

/// Manages the Claude Code CLI process lifecycle and NDJSON streaming.
///
/// Spawns the `claude` binary with stream-json I/O, reads stdout as an
/// ``AsyncStream<StreamEvent>``, and writes user messages to stdin in NDJSON format.
actor ClaudeService {

    // MARK: - State

    /// Concurrently running processes — managed independently per streamId
    private var processes: [UUID: Process] = [:]
    /// Writable stdin handles per stream — used for sending follow-up messages (e.g., AskUserQuestion responses).
    /// Entry is removed when stdin is closed (after `result` event or on cancel).
    private var stdinHandles: [UUID: FileHandle] = [:]
    /// Pending "force-kill after 5 s" tasks, keyed by streamId. Cancelled when the
    /// process exits naturally, so we never SIGKILL a recycled PID if the OS
    /// reassigns the pid to an unrelated process.
    private var cancelTasks: [UUID: Task<Void, Never>] = [:]

    /// Per-stream stderr accumulator — used to deliver error messages when process exits without a response
    private var stderrBuffers: [UUID: String] = [:]

    private var streamSessionIds: [UUID: String] = [:]

    private let cliStore: CLISessionStore
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudework",
        category: "ClaudeService"
    )

    init(cliStore: CLISessionStore) {
        self.cliStore = cliStore
    }

    // MARK: - Errors

    enum ClaudeError: LocalizedError {
        case binaryNotFound
        case versionCheckFailed(String)
        case processNotRunning
        case stdinUnavailable
        case spawnFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Could not find the claude CLI binary."
            case .versionCheckFailed(let detail):
                return "Version check failed: \(detail)"
            case .processNotRunning:
                return "No claude process is currently running."
            case .stdinUnavailable:
                return "stdin pipe is not available."
            case .spawnFailed(let detail):
                return "Failed to spawn claude process: \(detail)"
            }
        }
    }

    // MARK: - Shell PATH Resolution

    /// Cached PATH used for spawned subprocesses. Built once on first use.
    ///
    /// macOS GUI apps inherit a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`)
    /// that excludes Homebrew, nvm, and npm-global locations. Without overriding
    /// PATH for spawned processes, the `claude` CLI fails with
    /// `env: node: No such file or directory` when its `node` shebang resolver
    /// cannot locate Node.
    private var cachedShellPath: String?

    /// Cached env dictionary exported by the user's interactive login shell.
    /// Built once on first use. macOS GUI processes do not inherit the
    /// user's `~/.zshrc` exports, so third-party routing variables
    /// (e.g. `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`) silently disappear
    /// unless we re-read the login shell.
    private var cachedShellEnv: [String: String]?

    /// Compose a PATH that lets the spawned `claude` CLI find `node` and
    /// related tools regardless of where the user installed them.
    ///
    /// Combines, in priority order:
    ///   1. The user's interactive login shell PATH (captures nvm/asdf/.zshrc init)
    ///   2. Well-known tool directories (Homebrew, npm-global, nvm latest)
    ///   3. The GUI process's existing PATH as a final fallback
    private func resolvedShellPath() async -> String {
        if let cached = cachedShellPath { return cached }

        var paths: [String] = []
        var seen = Set<String>()
        func add(_ entry: String) {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            paths.append(trimmed)
        }

        if let shellPath = await readUserShellPath() {
            for component in shellPath.split(separator: ":") { add(String(component)) }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
        ] { add(dir) }

        if let nvmBin = latestNvmBinDirectory(home: home) { add(nvmBin) }

        if let existing = ProcessInfo.processInfo.environment["PATH"] {
            for component in existing.split(separator: ":") { add(String(component)) }
        }

        // Double-check after awaits: another reentrant caller may have populated it.
        if let cached = cachedShellPath { return cached }

        let combined = paths.joined(separator: ":")
        cachedShellPath = combined
        logger.info("Resolved shell PATH for subprocess (entries=\(paths.count))")
        return combined
    }

    /// Spawn the user's login shell once to read its `$PATH`.
    /// Uses `-ilc` so `.zshrc` (and the nvm/asdf init it typically sources) runs.
    private func readUserShellPath() async -> String? {
        do {
            let output = try await runShellCommand(
                "/bin/zsh",
                arguments: ["-ilc", "print -rn -- $PATH"],
                injectPath: false
            )
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            logger.warning("Failed to read user shell PATH: \(error.localizedDescription)")
            return nil
        }
    }

    /// Locate the bin directory of the most recent nvm-installed Node, if any.
    /// Defends against shell readout failure for nvm users.
    private func latestNvmBinDirectory(home: String) -> String? {
        let root = "\(home)/.nvm/versions/node"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for entry in entries.sorted(by: >) {
            let bin = "\(root)/\(entry)/bin"
            if fm.isExecutableFile(atPath: "\(bin)/node") { return bin }
        }
        return nil
    }

    /// Build the full environment dictionary for spawned subprocesses.
    ///
    /// Starts from the GUI process's env, then layers the user's login shell
    /// exports on top so that third-party routing variables
    /// (e.g. `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`) reach the spawned
    /// `claude` CLI. PATH is always overridden with ``resolvedShellPath()``
    /// since the curated PATH survives the GUI launch context better than
    /// the raw shell PATH for this use case.
    private func resolvedEnvironment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let shellEnv = await readUserShellEnv() {
            for (key, value) in shellEnv where key != "PATH" { env[key] = value }
        }
        env["PATH"] = await resolvedShellPath()
        return env
    }

    /// Read all env vars exported by the user's interactive login shell.
    ///
    /// Uses `zsh -ilc "env -0"` so the user's `.zshrc` (and `nvm`/`asdf` init
    /// it typically sources) is loaded and `export FOO=bar` lines are visible.
    /// The `-0` flag produces NUL-separated records, robust to spaces and
    /// newlines inside values. Result is cached for the service lifetime.
    private func readUserShellEnv() async -> [String: String]? {
        if let cached = cachedShellEnv { return cached }
        do {
            let output = try await runShellCommand(
                "/bin/zsh",
                arguments: ["-ilc", "env -0"],
                injectPath: false
            )
            var parsed: [String: String] = [:]
            for entry in output.split(separator: "\0", omittingEmptySubsequences: true) {
                guard let eq = entry.firstIndex(of: "=") else { continue }
                let key = String(entry[..<eq])
                let value = String(entry[entry.index(after: eq)...])
                parsed[key] = value
            }
            if parsed.isEmpty { return nil }
            cachedShellEnv = parsed
            logger.info("Resolved shell env for subprocess (entries=\(parsed.count))")
            return parsed
        } catch {
            logger.warning("Failed to read user shell env: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Binary Discovery

    /// Well-known paths searched in order before falling back to the shell.
    private static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
    }

    /// Locate the `claude` binary on this machine.
    func findClaudeBinary() async -> String? {
        let fm = FileManager.default

        for path in Self.candidatePaths {
            // Resolve symlinks before checking
            let resolved = (path as NSString).resolvingSymlinksInPath
            if fm.fileExists(atPath: resolved) && fm.isExecutableFile(atPath: path) {
                logger.info("Found claude binary at \(path, privacy: .public) -> \(resolved, privacy: .public)")
                return path
            }
        }

        // Shell fallback
        logger.info("Trying shell fallback to locate claude binary")
        do {
            let result = try await runShellCommand("/bin/zsh", arguments: ["-ilc", "whence -p claude"])
            let path = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) {
                logger.info("Found claude binary via shell at \(path, privacy: .public)")
                return path
            }
        } catch {
            logger.warning("Shell fallback failed: \(error, privacy: .public)")
        }

        logger.error("claude binary not found")
        return nil
    }

    // MARK: - Local Command

    /// Run a local slash command (e.g. "/cost", "/usage") and return stdout.
    func runLocalCommand(_ command: String) async throws -> String {
        guard let binary = await findClaudeBinary() else {
            throw ClaudeError.binaryNotFound
        }

        let output = try await runShellCommand(binary, arguments: ["-p", command, "--output-format", "text"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run `/context` for a session and parse the used percentage.
    /// Returns nil if the session has no context info or parsing fails.
    func fetchContextPercentage(sessionId: String, cwd: String) async -> Double? {
        guard let binary = await findClaudeBinary() else { return nil }
        do {
            let output = try await runShellCommand(
                binary,
                arguments: ["-p", "/context", "--output-format", "text", "--resume", sessionId],
                cwd: cwd
            )
            // Parse "Tokens: 24.2k / 200k (12%)" pattern
            guard let match = output.range(of: #"\((\d+(?:\.\d+)?)%\)"#, options: .regularExpression) else {
                return nil
            }
            let captured = output[match].dropFirst(1).dropLast(2) // remove "(" and "%)"
            return Double(captured)
        } catch {
            logger.warning("Failed to fetch context: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Compact Session

    /// Run a one-shot context compaction: ask Claude to summarize the
    /// conversation of an existing session. Returns the summary text
    /// (which the caller is expected to insert as a fresh assistant
    /// message in place of the old history).
    ///
    /// Implementation: spawn `claude -p "Summarize..." --resume <sid>
    /// --system-prompt <summaryPrompt> --output-format text --model
    /// <model>` and return the full stdout.
    func compactSession(
        sessionId: String,
        model: String,
        cwd: String?
    ) async throws -> String {
        guard let binary = await findClaudeBinary() else {
            throw ClaudeError.binaryNotFound
        }

        let summaryPrompt = """
        You are performing a CONTEXT CHECKPOINT COMPACTION for an existing \
        Claude Code session. Produce a handoff summary that another LLM \
        can use to resume the task.

        Include:
        1. Current progress and key decisions made.
        2. Important context, constraints, and user preferences.
        3. What remains to be done.
        4. Any critical data, file paths, or tool outputs needed to continue.

        Be concise. The summary will replace the conversation history.
        """

        let arguments = [
            "-p",
            "Summarize the conversation above this point.",
            "--resume", sessionId,
            "--system-prompt", summaryPrompt,
            "--output-format", "text",
            "--model", model
        ]

        let output = try await runShellCommand(binary, arguments: arguments, cwd: cwd)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Version Check

    /// Run `claude --version` and return the version string.
    func checkVersion() async throws -> String {
        guard let binary = await findClaudeBinary() else {
            throw ClaudeError.binaryNotFound
        }

        let output = try await runShellCommand(binary, arguments: ["--version"])
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s*\(Claude Code\)"#, with: "", options: .regularExpression)

        guard !version.isEmpty else {
            throw ClaudeError.versionCheckFailed("Empty version output")
        }

        logger.info("Claude CLI version: \(version, privacy: .public)")
        return version
    }

    // MARK: - Send (spawn + stream)

    /// Spawn the CLI and return a stream of parsed events.
    ///
    /// Architecture: a single `Task.detached` reads stdout line-by-line,
    /// decodes NDJSON, and yields `StreamEvent`s. No intermediate streams,
    /// no shared-actor scheduling issues.
    ///
    /// Multiple concurrent streams are managed independently via `streamId`.
    func send(
        streamId: UUID,
        prompt: String,
        cwd: String,
        sessionId: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        hookSettingsPath: String? = nil,
        permissionMode: PermissionMode = .default
    ) -> AsyncStream<StreamEvent> {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        let log = self.logger
        let currentStreamId = streamId

        readStderr(stderr, streamId: currentStreamId)

        return AsyncStream<StreamEvent> { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                // Spawn process (hops to ClaudeService actor for state)
                do {
                    try await self.spawnProcess(
                        streamId: streamId,
                        prompt: prompt,
                        cwd: cwd,
                        sessionId: sessionId,
                        model: model,
                        effort: effort,
                        hookSettingsPath: hookSettingsPath,
                        permissionMode: permissionMode,
                        stdinPipe: stdin,
                        stdoutPipe: stdout,
                        stderrPipe: stderr,
                        onProcessExit: {
                            // Wait 2 seconds after process exit to flush remaining buffers
                            // before finishing the stream. continuation.finish() is thread-safe and
                            // idempotent, so duplicate calls on normal exit are safe.
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                                continuation.finish()
                            }
                        }
                    )
                } catch {
                    log.error("[Stream] spawn failed: \(error.localizedDescription)")
                    continuation.finish()
                    return
                }

                // Read stdout line-by-line — ends naturally at EOF
                var parsedCount = 0
                var failedCount = 0
                let decoder = JSONDecoder()
                log.info("[Stream] starting stdout read loop")

                var rawLineCount = 0
                var capturedSessionId: String?
                do {
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        guard !line.isEmpty else { continue }
                        guard let data = line.data(using: .utf8) else { continue }

                        rawLineCount += 1
                        // Diagnostic logging of raw NDJSON — full content for first 30 lines, then type field only
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            let type = (json["type"] as? String) ?? "?"
                            if rawLineCount <= 30 {
                                log.info("[Stream:RAW] #\(rawLineCount) type=\(type) line=\(line.prefix(600))")
                            } else if type == "stream_event" || rawLineCount % 50 == 0 {
                                log.info("[Stream:RAW] #\(rawLineCount) type=\(type)")
                            }
                            if capturedSessionId == nil,
                               let sid = (json["session_id"] as? String) ?? (json["sessionId"] as? String) {
                                capturedSessionId = sid
                                // AWAIT synchronously: this is inside a
                                // detached stream-read Task running on the
                                // actor's cooperative pool. Awaiting here
                                // (a) hops to the actor, (b) records the
                                // sessionId, (c) hops back, in that order.
                                // The terminationHandler's Task also hops
                                // to the actor; per Swift's actor FIFO
                                // ordering for Tasks spawned on the same
                                // actor, our record-sessionId hop will
                                // complete before the termination handler
                                // runs, so consumeSessionId in the handler
                                // will see the value. A fire-and-forget
                                // `Task { ... }` would race.
                                await self.recordSessionId(streamId: streamId, sessionId: sid)
                            }
                        } else if rawLineCount <= 30 {
                            log.info("[Stream:RAW] #\(rawLineCount) non-JSON line=\(line.prefix(600))")
                        }

                        do {
                            let event = try decoder.decode(StreamEvent.self, from: data)
                            parsedCount += 1
                            continuation.yield(event)
                        } catch {
                            failedCount += 1
                            // Yield raw string so partial events still reach the UI
                            continuation.yield(.unknown(line))
                            if failedCount <= 5 {
                                log.warning("[Stream] parse failed #\(failedCount): \(line.prefix(200))")
                            }
                        }
                    }
                } catch {
                    log.warning("[Stream] stdout read error: \(error.localizedDescription)")
                }

                log.info("[Stream] stdout ended (parsed=\(parsedCount), failed=\(failedCount))")
                continuation.finish()
            }

            continuation.onTermination = { reason in
                log.info("[Stream] terminated (reason=\(String(describing: reason)))")
                task.cancel()
                // Close the pipe after the stream ends to unblock the bytes.lines read.
                // onTermination is called after finish(), so there is no data loss.
                stdout.fileHandleForReading.closeFile()
            }
        }
    }

    // MARK: - Cancel

    /// Terminate the process corresponding to a given streamId (SIGINT → SIGKILL after 5 seconds).
    func cancel(streamId: UUID) {
        guard let process = processes[streamId], process.isRunning else { return }
        // Cancel any previously-scheduled kill (idempotency).
        cancelTasks[streamId]?.cancel()

        logger.info("Sending SIGINT to claude process \(process.processIdentifier) (stream=\(streamId))")
        process.interrupt() // SIGINT

        // Schedule a forced kill after 5 seconds if still alive.
        // The kill task is stored in `cancelTasks` and cancelled by the
        // termination handler when the process exits, so we never SIGKILL a
        // pid that the OS has already recycled for an unrelated process.
        let pid = process.processIdentifier
        let log = logger
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            await self?.forceKillIfStillOurs(streamId: streamId, pid: pid, log: log)
        }
        cancelTasks[streamId] = task
    }

    /// SIGKILL `pid` only if the actor still owns the same running process
    /// (guards against the OS recycling the pid after the original process
    /// exited but before our 5 s timer fired).
    private func forceKillIfStillOurs(streamId: UUID, pid: Int32, log: Logger) {
        // Drop our handle to the kill task — it's either running now or done.
        cancelTasks.removeValue(forKey: streamId)
        guard let current = processes[streamId], current.isRunning,
              current.processIdentifier == pid else {
            // Process already exited (or the dictionary entry was replaced),
            // so the pid may now belong to an unrelated process. Do nothing.
            return
        }
        log.warning("Process \(pid) still running after 5 s, sending SIGKILL")
        kill(pid, SIGKILL)
    }

    // MARK: - Private Helpers

    /// Build arguments array for the CLI invocation.
    ///
    /// The user prompt is NOT a CLI argument — it is written to stdin as a JSON
    /// user message (see `spawnProcess`) because we run the CLI with
    /// `--input-format stream-json`.
    private func buildArguments(
        sessionId: String?,
        model: String?,
        effort: String?,
        hookSettingsPath: String?,
        permissionMode: PermissionMode
    ) -> [String] {
        var args: [String] = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]

        // Map Clarc's `.fullAccess` to the CLI's `bypassPermissions` token;
        // the wildcard `--allowedTools "*"` (emitted below) carries the
        // "all tools pre-approved" semantics that distinguishes it from
        // plain bypass.
        if permissionMode != .default {
            args += ["--permission-mode", permissionMode.cliPermissionModeValue]
        }

        if permissionMode.usesWildcardAllowedTools {
            // Wildcard pre-approves every tool at the CLI layer so no tool
            // call ever blocks on the permission modal. The hook pipeline
            // is skipped (skipsHookPipeline == true) so we never write
            // PreToolUse hook settings — there's nothing for the hook to
            // intercept.
            args += ["--allowedTools", "*"]
        } else if !permissionMode.skipsHookPipeline {
            // Pre-approve safe tools that don't need to go through hooks via --allowedTools.
            // This eliminates HTTP round-trips from internal agent mechanics like Read/Grep/Task,
            // since no approval UI is shown for these.
            let safeTools = [
                "Read", "Glob", "Grep", "LS",
                "TodoRead", "TodoWrite",
                "Agent", "Task", "TaskOutput",
                "Notebook", "NotebookEdit",
                "WebSearch", "WebFetch",
            ]
            args += ["--allowedTools", safeTools.joined(separator: ",")]
        }

        if let hookSettingsPath {
            args += ["--settings", hookSettingsPath]
        }

        if let sessionId {
            args += ["--resume", sessionId]
        }

        if let model {
            args += ["--model", model]
        }

        if let effort {
            args += ["--effort", effort]
        }

        // With `--input-format stream-json`, the prompt is sent via stdin as a JSON
        // user message (see spawnProcess) rather than as a CLI argument.
        return args
    }

    /// Actually launch the `Process`.
    private func spawnProcess(
        streamId: UUID,
        prompt: String,
        cwd: String,
        sessionId: String?,
        model: String?,
        effort: String? = nil,
        hookSettingsPath: String?,
        permissionMode: PermissionMode = .default,
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        onProcessExit: (@Sendable () -> Void)? = nil
    ) async throws {
        guard let binary = await findClaudeBinary() else {
            throw ClaudeError.binaryNotFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = buildArguments(
            sessionId: sessionId,
            model: model,
            effort: effort,
            hookSettingsPath: hookSettingsPath,
            permissionMode: permissionMode
        )
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Inherit a reasonable environment so the CLI can find config files, etc.,
        // and override PATH so the `node` shebang in `claude` resolves under GUI launch.
        proc.environment = await resolvedEnvironment()

        let log = logger
        proc.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let reason = process.terminationReason
            log.info(
                "claude process exited — status: \(status), reason: \(reason.rawValue), stream=\(streamId)"
            )
            Task {
                await self?.removeProcess(streamId: streamId)
                if let sid = await self?.consumeSessionId(streamId: streamId) {
                    await self?.cliStore.exposeToPicker(sid: sid, cwd: cwd)
                }
            }
            onProcessExit?()
        }

        do {
            try proc.run()
            // Keep stdin open for stream-json input protocol.
            // The CLI reads NDJSON messages from stdin until EOF; closing stdin
            // is how we signal "no more input" and let the process exit cleanly.
            // This happens in `closeStdin(streamId:)` after the `result` event.
            let stdinHandle = stdinPipe.fileHandleForWriting
            self.processes[streamId] = proc
            self.stdinHandles[streamId] = stdinHandle

            // Send the initial user prompt as an NDJSON user message.
            let userMessage: [String: Any] = [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt]
                    ]
                ]
            ]
            do {
                try Self.writeJSONLine(userMessage, to: stdinHandle)
            } catch {
                // The process has already started. If we can't deliver the
                // initial prompt, the CLI will block on stdin forever and
                // become an orphan — there's no way to feed it the prompt
                // later, and the user sees a hung UI. Kill the process and
                // clean up our bookkeeping before re-throwing.
                logger.error("Failed to write initial prompt: \(error.localizedDescription, privacy: .public). Killing stream=\(streamId)")
                if proc.isRunning {
                    proc.terminate()
                }
                self.processes.removeValue(forKey: streamId)
                self.stdinHandles.removeValue(forKey: streamId)
                throw ClaudeError.spawnFailed(error.localizedDescription)
            }

            logger.info(
                "Spawned claude process pid=\(proc.processIdentifier) cwd=\(cwd, privacy: .public) stream=\(streamId)"
            )
        } catch {
            logger.error("Failed to spawn claude: \(error, privacy: .public)")
            // Ensure no orphan survives even if run() itself failed.
            if proc.isRunning {
                proc.terminate()
            }
            self.processes.removeValue(forKey: streamId)
            self.stdinHandles.removeValue(forKey: streamId)
            // Close all pipe FDs so they don't leak on spawn failure. The
            // normal path closes stdout via continuation.onTermination in
            // send(); on the failure path that handler never fires because
            // continuation.finish() was already called. Swallow close errors
            // — we are already on the failure path and a secondary error
            // here would mask the original spawn error.
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            throw ClaudeError.spawnFailed(error.localizedDescription)
        }
    }

    // MARK: - Stdin Writer

    /// Serialize a dictionary to JSON and write to stdin as one NDJSON line.
    /// Non-isolated to allow use from `spawnProcess` after `try proc.run()`.
    private static func writeJSONLine(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        handle.write(data)
        handle.write(Data([0x0A])) // newline
    }

    /// Close stdin for an active stream. Call this after receiving the `result` event
    /// so the CLI process exits cleanly once it has flushed all remaining output.
    func closeStdin(streamId: UUID) {
        guard let handle = stdinHandles.removeValue(forKey: streamId) else { return }
        do {
            try handle.close()
            logger.info("Closed stdin for stream=\(streamId)")
        } catch {
            logger.warning("closeStdin error for stream=\(streamId): \(error.localizedDescription)")
        }
    }

    /// Remove a process from within actor isolation, called from terminationHandler.
    private func removeProcess(streamId: UUID) {
        // Cancel any pending "force-kill after 5 s" task — the process is
        // exiting (or has already exited), so we must not SIGKILL a pid that
        // may have been recycled by the OS.
        cancelTasks.removeValue(forKey: streamId)?.cancel()
        processes.removeValue(forKey: streamId)
        // If stdin is still open (e.g. abnormal exit before `result`), release the handle.
        if let handle = stdinHandles.removeValue(forKey: streamId) {
            try? handle.close()
        }
        // Drop per-stream state that otherwise accumulates forever on
        // abnormal exits (the consume* helpers that read these only run
        // on the happy path of receiving a `result` event).
        stderrBuffers.removeValue(forKey: streamId)
        // sessionId is consumed by `consumeSessionId` during the
        // termination handler, so don't remove it here — the handler
        // hasn't run its body yet when this method is called.
    }

    private func recordSessionId(streamId: UUID, sessionId: String) {
        streamSessionIds[streamId] = sessionId
    }

    private func consumeSessionId(streamId: UUID) -> String? {
        streamSessionIds.removeValue(forKey: streamId)
    }

    /// Read stderr asynchronously, log each line, and buffer for error reporting.
    private nonisolated func readStderr(_ pipe: Pipe, streamId: UUID) {
        let log = logger
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                pipe.fileHandleForReading.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    log.debug("[stderr] \(line, privacy: .public)")
                }
                Task { await self?.appendStderr(text, for: streamId) }
            }
        }
    }

    /// Append text to the stderr buffer
    private func appendStderr(_ text: String, for streamId: UUID) {
        stderrBuffers[streamId, default: ""] += text
    }

    /// Consume and return the stderr buffer for a given stream
    func consumeStderr(for streamId: UUID) -> String? {
        guard let buffer = stderrBuffers.removeValue(forKey: streamId),
              !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run a simple command and return its stdout as a String.
    /// Uses async termination handling to avoid blocking the actor's cooperative thread.
    ///
    /// `injectPath` controls whether the spawned process receives the resolved
    /// shell PATH. Set to `false` when this method is itself used to *resolve*
    /// the shell PATH, to break the chicken-and-egg loop.
    private func runShellCommand(
        _ command: String,
        arguments: [String] = [],
        cwd: String? = nil,
        injectPath: Bool = true
    ) async throws -> String {
        let proc = Process()
        let pipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.environment = injectPath
            ? await resolvedEnvironment()
            : ProcessInfo.processInfo.environment
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        try proc.run()

        // Wait for process exit asynchronously instead of blocking
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in
                continuation.resume()
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Cleanup

    /// Tear down any resources held by the service.
    func cleanup() {
        for (_, process) in processes where process.isRunning {
            process.interrupt()
        }
        processes.removeAll()
        for (_, handle) in stdinHandles {
            try? handle.close()
        }
        stdinHandles.removeAll()
    }
}
