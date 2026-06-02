import Foundation

/// Builds `TaskUpdateMessage` values from the tool lifecycle events
/// Clarc already receives on the streaming path (tool_use arrival,
/// input_json_delta completion, tool_result).
///
/// This is what makes the Codex-style phase cards actually appear in
/// the chat: every Bash/Edit/Write/Read/Agent call gets a card without
/// the model having to emit any `task_update` JSON. The model-emit
/// path still works (TaskUpdateParser.extract) for compatibility.
public enum TaskUpdateMessageFactory {

    /// Build an initial running card for a tool_use arrival. The
    /// `input` here may still be empty (the stream buffers it
    /// incrementally) — the caller should re-call `makeWithInput`
    /// once the input is finalized.
    public static func makeRunning(
        name: String,
        id: String
    ) -> TaskUpdateMessage {
        TaskUpdateMessage(
            id: UUID(uuidString: id) ?? UUID(),
            title: titleFor(name: name),
            summary: "running…",
            details: "",
            status: .running,
            startTime: Date()
        )
    }

    /// Build a fresh `TaskUpdateMessage` from a fully-decoded tool
    /// call. Used when the stream knows both the name and the parsed
    /// input. Replaces a previously-created running card.
    public static func makeWithInput(
        name: String,
        id: String,
        input: [String: JSONValue],
        existingStartTime: Date?
    ) -> TaskUpdateMessage {
        TaskUpdateMessage(
            id: UUID(uuidString: id) ?? UUID(),
            title: titleFor(name: name),
            summary: summaryFor(name: name, input: input),
            details: detailsFor(name: name, input: input),
            status: .running,
            startTime: existingStartTime ?? Date(),
            filesChanged: filesFor(name: name, input: input)
        )
    }

    /// Mark the card done/failed. Preserves start time and the rest
    /// of the populated fields; only the lifecycle bits change.
    public static func finalize(
        from running: TaskUpdateMessage,
        result: String?,
        isError: Bool
    ) -> TaskUpdateMessage {
        let now = Date()
        return TaskUpdateMessage(
            id: running.id,
            title: running.title,
            summary: resultSummaryFor(result: result, isError: isError) ?? running.summary,
            details: running.details,
            status: isError ? .failed : .done,
            startTime: running.startTime,
            endTime: now,
            durationSeconds: now.timeIntervalSince(running.startTime),
            filesChanged: running.filesChanged,
            testResults: testResultsFor(result: result)
        )
    }

    // MARK: - Title

    private static func titleFor(name: String) -> String {
        switch name.lowercased() {
        case "bash":           return "Bash"
        case "edit":           return "Edit"
        case "multiedit",
             "multi_edit":     return "Edit"
        case "write":          return "Write"
        case "read":           return "Read"
        case "glob":           return "Glob"
        case "grep":           return "Grep"
        case "ls":             return "LS"
        case "agent",
             "task":           return "Agent"
        case "taskoutput",
             "task_output":   return "Task Output"
        case "askuserquestion": return "Question"
        case "todowrite":      return "Todo"
        case "todoread":       return "Todo"
        case "websearch":      return "Web Search"
        case "webfetch":       return "Web Fetch"
        case "notebook":       return "Notebook"
        case "notebookedit":   return "Notebook"
        case "skill":          return "Skill"
        default:               return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    // MARK: - Summary

    private static func summaryFor(name: String, input: [String: JSONValue]) -> String {
        switch name.lowercased() {
        case "bash":
            if let cmd = input["command"]?.stringValue {
                return truncate(firstLine(of: cmd), to: 80)
            }
        case "edit", "multiedit", "multi_edit":
            if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue {
                return path
            }
        case "write":
            if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue {
                return path
            }
        case "read":
            if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue {
                return path
            }
        case "glob":
            if let pattern = input["pattern"]?.stringValue {
                return pattern
            }
        case "grep":
            if let pattern = input["pattern"]?.stringValue ?? input["query"]?.stringValue {
                return truncate(pattern, to: 80)
            }
        case "ls":
            if let path = input["path"]?.stringValue {
                return path
            }
        case "agent", "task":
            if let desc = input["description"]?.stringValue {
                return truncate(desc, to: 80)
            }
        case "websearch":
            if let q = input["query"]?.stringValue {
                return truncate(q, to: 80)
            }
        case "webfetch":
            if let url = input["url"]?.stringValue {
                return url
            }
        case "skill":
            if let s = input["skill"]?.stringValue {
                return s
            }
        case "askuserquestion":
            if let q = input["question"]?.stringValue {
                return truncate(q, to: 80)
            }
        default:
            break
        }
        return name
    }

    // MARK: - Details

    private static func detailsFor(name: String, input: [String: JSONValue]) -> String {
        switch name.lowercased() {
        case "bash":
            if let cmd = input["command"]?.stringValue {
                return cmd
            }
        case "edit", "multiedit", "multi_edit":
            var lines: [String] = []
            if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue {
                lines.append("file: \(path)")
            }
            if let old = input["old_string"]?.stringValue {
                lines.append("old:\n\(old)")
            }
            if let new = input["new_string"]?.stringValue {
                lines.append("new:\n\(new)")
            }
            if !lines.isEmpty { return lines.joined(separator: "\n\n") }
        case "write":
            if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue,
               let content = input["content"]?.stringValue {
                return "file: \(path)\n\n\(content)"
            }
        case "read", "glob", "grep", "ls":
            // Read/glob/grep/ls are tool inputs that are mostly useful
            // to the model; surfacing them as "details" would just be
            // noise in the collapsed card.
            return ""
        case "agent", "task":
            var lines: [String] = []
            if let desc = input["description"]?.stringValue {
                lines.append("description: \(desc)")
            }
            if let sub = input["subagent_type"]?.stringValue {
                lines.append("type: \(sub)")
            }
            if let prompt = input["prompt"]?.stringValue {
                lines.append("prompt:\n\(prompt)")
            }
            if !lines.isEmpty { return lines.joined(separator: "\n\n") }
        default:
            break
        }

        // Fallback: render the raw input as pretty JSON so the
        // expanded card is at least informative for any tool.
        guard let data = try? JSONEncoder().encode(input),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: - Files

    private static func filesFor(name: String, input: [String: JSONValue]) -> [TaskFileChange] {
        let lower = name.lowercased()
        guard lower == "edit" || lower == "multiedit" || lower == "multi_edit" || lower == "write" else {
            return []
        }
        guard let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue,
              !path.isEmpty else { return [] }
        return [TaskFileChange(
            path: path,
            additions: nil,
            deletions: nil,
            changeType: lower == "write" ? "added" : "modified"
        )]
    }

    // MARK: - Test results (best-effort text scan)

    private static func testResultsFor(result: String?) -> [TaskTestResult] {
        guard let result, !result.isEmpty else { return [] }
        // Look for the common patterns emitted by `npm test`,
        // `cargo test`, `pytest`, `go test`, etc.:
        //   "X passed", "Y failed", "Z skipped"
        // We only emit one summary row so the card stays compact.
        let passed = matches(in: result, pattern: #"(\d+)\s+passed"#).first
        let failed = matches(in: result, pattern: #"(\d+)\s+failed"#).first
        let skipped = matches(in: result, pattern: #"(\d+)\s+skipped"#).first
        let any = passed ?? failed ?? skipped
        guard any != nil else { return [] }

        let name = "Tests"
        let status: String
        if (failed?.intValue ?? 0) > 0 {
            status = "failed"
        } else {
            status = "passed"
        }
        return [TaskTestResult(name: name, status: status, durationSeconds: nil)]
    }

    // MARK: - Helpers

    private static func resultSummaryFor(result: String?, isError: Bool) -> String? {
        guard let result, !result.isEmpty else { return nil }
        let first = firstLine(of: result)
        return truncate(first, to: 80)
    }

    private static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private static func truncate(_ s: String, to n: Int) -> String {
        if s.count <= n { return s }
        let idx = s.index(s.startIndex, offsetBy: n - 1)
        return s[..<idx] + "…"
    }

    private static func matches(in text: String, pattern: String) -> [NSNumber] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: text) else { return nil }
            return Int(text[r]) as NSNumber?
        }
    }
}
