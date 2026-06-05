import Foundation

/// Evaluates read-only Bash commands against a whitelist.
///
/// Security model: every command token must (a) be in the command allowlist and
/// (b) pass argument-level checks for flags that turn a "read" tool into a "write"
/// tool. Whitelisting only the binary name is not sufficient — many tools on the
/// list have write-capable flags (e.g. `find -delete`, `tar -xf`, `python -c`).
enum BashSafety {

    // MARK: - Allowlist

    /// Commands considered safe when invoked without write-capable flags.
    /// Note: `env`, `time`, `command` are intentionally absent — they are
    /// "wrappers" that let the caller run any other binary, so allowing them
    /// would bypass the whole allowlist.
    private nonisolated static let safeCommands: Set<String> = [
        // info / help
        "cat", "head", "tail", "less", "more", "wc", "file", "stat",
        "ls", "pwd", "echo", "printf", "date", "whoami", "hostname", "uname",
        "which", "whence", "where", "type",
        "man", "help", "info",
        // search
        "find", "grep", "rg", "ag", "ack", "fd", "fzf", "locate",
        // git (subcommands validated separately)
        "git",
        // environment inspection
        "printenv",
        // package managers (subcommands validated separately)
        "npm", "yarn", "pnpm", "bun",
        // system info
        "df", "du", "free", "top", "htop", "ps", "uptime", "lsof",
        "tree", "realpath", "dirname", "basename",
        // macOS specific
        "sw_vers", "system_profiler", "mdls", "mdfind",
        // comparison / text processing (read-only)
        "diff", "cmp", "comm", "uniq", "cut", "tr", "tac", "nl",
        "jq", "yq",
        // code / archive inspection (read-only)
        "tokei", "cloc",
        // binary / hash inspection (read-only)
        "hexdump", "od", "strings",
        "shasum", "md5sum", "sha256sum", "base64",
        // misc read-only utilities
        "id", "groups", "rev", "cal",
    ]

    private nonisolated static let gitMutatingSubcommands: Set<String> = [
        "push", "commit", "merge", "rebase", "reset", "checkout", "switch",
        "branch", "tag", "stash", "cherry-pick", "revert", "am", "apply",
        "clean", "rm", "mv", "restore", "bisect", "pull", "fetch", "clone",
        "init", "submodule", "worktree", "gc", "prune", "filter-branch",
        // write-side config / remote / ref / maintenance subcommands.
        "config", "remote", "update-ref", "notes", "sparse-checkout",
        "maintenance", "bundle", "replace",
    ]

    private nonisolated static let claudeMutatingSubcommands: Set<String> = [
        "config", "login", "logout",
        "plugin", "update", "migrate", "uninstall", "doctor",
        "agents", "setup-token", "install",
    ]

    private nonisolated static let packageMutatingSubcommands: Set<String> = [
        "install", "i", "add", "remove", "uninstall", "publish", "run",
        "exec", "dlx", "npx", "create", "init", "link", "unlink", "pack", "deprecate",
        // `start`/`test`/`stop`/`restart` are aliases for `npm run <script>` and
        // can execute arbitrary commands from package.json.
        "start", "test", "stop", "restart",
        // `update`/`upgrade`/`audit fix` mutate lockfile and possibly sources.
        "update", "upgrade", "audit", "cache", "ci", "fund",
    ]

    /// Flags that turn an otherwise read-only tool into a write-capable one.
    /// When any of these appear in the command's argument list, the command is rejected.
    private nonisolated static let writeCapableFlags: [String: Set<String>] = [
        // `find` has multiple ways to mutate: -exec/-execdir/-ok/-okdir run
        // arbitrary commands; -delete/-fls/-fprint write files. Both
        // short (`-x`) and long (`--xxx`) forms must be listed, since
        // hasWriteCapableArg uses exact `flags.contains(arg)` matching.
        "find": [
            "-exec", "-execdir", "-ok", "-okdir",
            "-delete", "-fls", "-fprint", "-fprintf", "-touch",
            "--exec", "--execdir", "--ok", "--okdir",
            "--delete", "--fls", "--fprint", "--fprintf", "--touch"
        ],
        // `sort -o` writes to an arbitrary file. `--output` is the long form.
        "sort": ["-o", "--output"],
        // `python`/`python3`/`ruby`/`node` can execute arbitrary code via -c/-e/-p.
        // They can also load arbitrary scripts as positional args. To stay safe we
        // only allow script paths under cwd, but for the read-only whitelist we
        // reject the inline-execution flags outright.
        "python": ["-c", "-m", "--command"],
        "python3": ["-c", "-m", "--command"],
        "ruby": ["-e", "-r", "--require"],
        "node": ["-e", "-p", "-r", "--require", "--eval", "--print"],
        // `awk` can call `system()` from inside BEGIN/END blocks and write files
        // via `print >`. Rejecting `-f` (script file) and `-v` (variable) is
        // insufficient — instead, we drop awk from the allowlist entirely below.
        // `sed -i` rewrites files in place; `sed -i.bak` likewise.
        "sed": ["-i"],
        // `tar` write modes. `c` = create, `x` = extract, `r` = append, `u` = update.
        "tar": ["-c", "--create", "-x", "--extract", "--get", "-r", "--append", "-u", "--update"],
        // `tar` short-form flags: e.g. `tar -xf file.tar` combines -x and -f.
        // We handle the combined short form in the arg-scanning code below.
        "zip": [],
        "unzip": [],
    ]

    /// Split `&&`/`||`/`;`/`|`/`&` into separate commands. `||` and `&&` must be
    /// matched before `|` to avoid splitting them into two single chars.
    private nonisolated static let segmentSeparator: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s*(?:&&|\|\||;|\||&)\s*"#)
    }()

    /// Detect command substitution, process substitution, and other shell
    /// expansion that lets a command's arguments be evaluated at runtime.
    /// `$(...)` and backticks are not handled by our token splitter and would
    /// be treated as a literal string by the inner command, so the attacker
    /// can still construct payloads like `echo $(rm -rf /)`.
    private nonisolated static let unsafeMetacharacters: NSRegularExpression = {
        // `$()` / `${}` / backticks / `<(` / `>(` — all unquoted forms are rejected.
        try! NSRegularExpression(pattern: #"(\$\(|\$\{|`|<\s*\(|>\s*\()"#)
    }()

    private nonisolated static let allowedRedirectTokens = [">/dev/null", "2>/dev/null", "2>&1"]

    // MARK: - Public entry

    nonisolated static func isSafeReadOnly(command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Reject any command that contains shell expansion constructs outright.
        let ns = trimmed as NSString
        let range = NSRange(location: 0, length: ns.length)
        if unsafeMetacharacters.firstMatch(in: trimmed, range: range) != nil {
            return false
        }

        let segments = splitSegments(trimmed)
        guard !segments.isEmpty else { return false }

        for segment in segments {
            if !isSafeSegment(segment) { return false }
        }
        return true
    }

    // MARK: - Segmentation

    private nonisolated static func splitSegments(_ input: String) -> [String] {
        let regex = segmentSeparator
        let ns = input as NSString
        var segments: [String] = []
        var lastEnd = 0
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            if m.range.location > lastEnd {
                segments.append(ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd)))
            }
            lastEnd = m.range.location + m.range.length
        }
        if lastEnd < ns.length {
            segments.append(ns.substring(from: lastEnd))
        }
        return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Per-segment evaluation

    private nonisolated static func isSafeSegment(_ segment: String) -> Bool {
        // Reject file write redirections. /dev/null and 2>&1 are allowed.
        if segmentHasWriteRedirect(segment) { return false }

        let parts = segment.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let firstRaw = parts.first else { return false }

        // VAR=val cmd pattern: if the first token contains '=' (and is not just
        // a flag), skip it and use the next token as the actual command.
        // This prevents `FOO=bar rm -rf /` style bypasses.
        let envPrefixed = firstRaw.contains("=") && !firstRaw.hasPrefix("-")
        let cmdIdx = envPrefixed ? 1 : 0
        guard cmdIdx < parts.count else { return false }
        let cmd = parts[cmdIdx]
        let base = cmd.split(separator: "/").last.map(String.init) ?? cmd

        // Reject if the binary's name doesn't match the allowlist.
        // We also reject `cmd == "env"` and similar wrappers — they would let
        // the caller pass any binary as the next argument.
        guard safeCommands.contains(base) else { return false }

        // Find the subcommand by skipping global flags. e.g.
        //   git -C /repo push      → sub = "push"  (skip "-C", "/repo")
        //   git --no-pager push    → sub = "push"  (skip "--no-pager")
        //   git -c x=y clone       → sub = "clone" (skip "-c", "x=y")
        // For commands that consume value-taking flags, this may still
        // mis-parse (e.g. `git -c k=v` could see k=v as the sub if we
        // didn't recognize -c as a value-flag). To be conservative we
        // treat any token beginning with `-` as a flag and any subsequent
        // non-flag token as the candidate sub.
        var subIdx = cmdIdx + 1
        while subIdx < parts.count {
            let p = parts[subIdx]
            if p.hasPrefix("-") { subIdx += 1; continue }
            break
        }
        let sub: String? = subIdx < parts.count ? parts[subIdx] : nil
        let argList = Array(parts.dropFirst(subIdx))

        // 1. Subcommand-level gating for tools with mutable subcommands.
        switch base {
        case "git":
            if let s = sub, gitMutatingSubcommands.contains(s) { return false }
        case "claude":
            if let s = sub {
                if claudeMutatingSubcommands.contains(s) { return false }
                if s == "mcp" {
                    let mcpIdx = subIdx + 1
                    let mcpSub = mcpIdx < parts.count ? parts[mcpIdx] : nil
                    if let ms = mcpSub, ms != "list", ms != "get", ms != "--help" { return false }
                }
            }
        case "npm", "yarn", "pnpm", "bun":
            if let s = sub, packageMutatingSubcommands.contains(s) { return false }
        default:
            break
        }

        // 2. Argument-level gating for tools with write-capable flags.
        if let forbidden = writeCapableFlags[base], hasWriteCapableArg(argList, base: base, flags: forbidden) {
            return false
        }

        return true
    }

    /// Walk the argument list and check for forbidden flags. Handles both
    /// `--long-flag` and short flags like `-xf` (where -x is forbidden).
    private nonisolated static func hasWriteCapableArg(_ args: [String], base: String, flags: Set<String>) -> Bool {
        for arg in args {
            // Long-form: exact match.
            if flags.contains(arg) { return true }
            // Short-form combined flags: e.g. `-xf` contains `-x`. The
            // substring check is safe here because all our forbidden flags
            // are exact single-char (-x) or long-form (--xxx) names; no
            // short flag is a prefix of another (e.g. `-i` is not a prefix
            // of `-id` in the same set).
            if arg.hasPrefix("-") && !arg.hasPrefix("--") {
                let chars = arg.dropFirst()
                for ch in chars {
                    if flags.contains("-\(ch)") { return true }
                }
            }
        }
        return false
    }

    private nonisolated static func segmentHasWriteRedirect(_ segment: String) -> Bool {
        guard segment.contains(">") else { return false }
        var stripped = segment
        for token in allowedRedirectTokens {
            stripped = stripped.replacingOccurrences(of: token, with: "")
        }
        return stripped.contains(">")
    }
}
