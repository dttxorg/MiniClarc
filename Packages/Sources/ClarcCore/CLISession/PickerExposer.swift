import Foundation
import os

/// Rewrites Claude Code session jsonl files so that Clarc-spawned sessions
/// appear in the interactive `claude --resume` picker.
///
/// The CLI tags every line with `"entrypoint":"sdk-cli"` and prepends
/// `type: queue-operation` envelope lines whenever it is launched in print
/// mode (`-p`), which is how Clarc spawns it. The picker filters those
/// sessions out, so without this normalization Clarc's history is invisible
/// to anyone running `claude --resume` outside the app. Rewriting the file
/// to look like a regular interactive session lets the picker pick it up.
///
/// Patches are skipped while a sessionId is registered as live in
/// `~/.claude/sessions/<pid>.json`, so we never race the CLI's append.
public enum PickerExposer {

    private static let logger = Logger(subsystem: "com.claudework", category: "PickerExposer")

    private static let entrypointMarker = "\"entrypoint\":\"sdk-cli\""
    private static let entrypointReplacement = "\"entrypoint\":\"cli\""
    private static let queueOperationMarker = "\"type\":\"queue-operation\""

    /// Rewrite a single jsonl file. No-op if the session is still live.
    public static func normalize(jsonlAt url: URL) async {
        let sid = url.deletingPathExtension().lastPathComponent
        await Task.detached(priority: .utility) {
            if liveSessionIds().contains(sid) { return }
            normalizeSync(jsonlAt: url)
        }.value
    }

    /// Set of sessionIds with a live PID-keyed metadata file under
    /// `~/.claude/sessions/`. The CLI writes those on launch and removes
    /// them on clean exit; we use them to skip files mid-append.
    private static func liveSessionIds() -> Set<String> {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }
        var ids = Set<String>()
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String
            else { continue }
            ids.insert(sid)
        }
        return ids
    }

    private static func normalizeSync(jsonlAt url: URL) {
        let liveData: Data
        do {
            liveData = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return
        }
        guard let text = String(data: liveData, encoding: .utf8) else { return }

        guard text.contains(entrypointMarker) || text.contains(queueOperationMarker) else {
            return
        }

        // Snapshot the live file's length so we can detect any appends the CLI
        // makes between now and the atomic replaceItemAt below. Without this,
        // lines the CLI writes during normalization would be silently clobbered
        // by the rename (TOCTOU with the liveness check at the call site).
        let snapshotLength = liveData.count

        var out = String()
        out.reserveCapacity(text.utf8.count)
        var changed = false

        text.enumerateLines { line, _ in
            if line.contains(queueOperationMarker) {
                changed = true
                return
            }
            if line.contains(entrypointMarker) {
                out.append(line.replacingOccurrences(of: entrypointMarker, with: entrypointReplacement))
                out.append("\n")
                changed = true
                return
            }
            out.append(line)
            out.append("\n")
        }

        guard changed else { return }

        let dir = url.deletingLastPathComponent()
        // UUID-suffixed tmp avoids collisions when multiple normalizations
        // race on the same target.
        let tmp = dir.appendingPathComponent(
            ".\(url.lastPathComponent).picker-tmp.\(UUID().uuidString)"
        )
        do {
            // Non-atomic write: replaceItemAt below performs the single atomic rename.
            // .atomic here would write to a hidden sibling and rename, then replaceItemAt
            // would rename again — 2x FS work and a window where the target is missing.
            var payload = Data(out.utf8)
            // Tail the live file for any appends the CLI made during normalization
            // and merge them into the payload so replaceItemAt doesn't clobber them.
            if let tail = tailAppends(in: url, sinceOffset: snapshotLength) {
                payload.append(tail)
            }
            try payload.write(to: tmp, options: [])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            logger.error(
                "normalize failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Read any bytes appended to `url` after `sinceOffset`. Returns nil if the
    /// file is missing, shorter than the snapshot, or unreadable. The CLI writes
    /// jsonl append-only, so a length increase always means new trailing lines.
    private static func tailAppends(in url: URL, sinceOffset: Int) -> Data? {
        guard sinceOffset >= 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let endOffset: UInt64
        do {
            endOffset = try handle.seekToEnd()
        } catch {
            return nil
        }
        guard endOffset > UInt64(sinceOffset) else { return nil }
        do {
            try handle.seek(toOffset: UInt64(sinceOffset))
        } catch {
            return nil
        }
        return try? handle.readToEnd()
    }
}
