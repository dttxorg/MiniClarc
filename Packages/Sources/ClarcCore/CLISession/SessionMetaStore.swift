import Foundation
import os

/// Sidecar persistence for the Clarc-only fields that don't live in the CLI's
/// jsonl: title, isPinned, model, effort, permissionMode. One file per session
/// id at `~/Library/Application Support/Clarc/session-meta/{sid}.json`.
public actor SessionMetaStore {

    public struct Meta: Codable, Sendable {
        public var title: String?
        public var isPinned: Bool
        public var model: String?
        public var effort: String?
        public var permissionMode: PermissionMode?
        public var updatedAt: Date?

        public init(
            title: String? = nil,
            isPinned: Bool = false,
            model: String? = nil,
            effort: String? = nil,
            permissionMode: PermissionMode? = nil,
            updatedAt: Date? = nil
        ) {
            self.title = title
            self.isPinned = isPinned
            self.model = model
            self.effort = effort
            self.permissionMode = permissionMode
            self.updatedAt = updatedAt
        }
    }

    private let baseURL: URL
    private let logger = Logger(subsystem: "com.claudework", category: "SessionMetaStore")

    /// In-memory cache. The sidecar directory is owned exclusively by Clarc
    /// (CLI doesn't touch it), so the cache is authoritative once populated.
    private var cache: [String: Meta] = [:]

    public init() {
        self.baseURL = AppSupport.bundleScopedURL.appendingPathComponent("session-meta", isDirectory: true)
    }

    public func load(sessionId: String) -> Meta {
        if let cached = cache[sessionId] { return cached }
        let url = fileURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            let empty = Meta()
            cache[sessionId] = empty
            return empty
        }
        let meta = Self.decodeTolerant(data) ?? Meta()
        cache[sessionId] = meta
        return meta
    }

    public func save(sessionId: String, meta: Meta) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !(fm.fileExists(atPath: baseURL.path, isDirectory: &isDir) && isDir.boolValue) {
            try? fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }
        let url = fileURL(for: sessionId)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(meta)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to save session meta \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        // Only update the cache after a successful disk write. Otherwise
        // a failed write (disk full, permissions) would leave the in-memory
        // cache ahead of disk, and the next `load` after restart would
        // return the stale on-disk value (e.g. pin title disappears).
        cache[sessionId] = meta
    }

    public func delete(sessionId: String) {
        cache.removeValue(forKey: sessionId)
        let url = fileURL(for: sessionId)
        try? FileManager.default.removeItem(at: url)
    }

    public func loadAll() -> [String: Meta] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return [:]
        }
        var result: [String: Meta] = [:]
        for file in files where file.pathExtension == "json" {
            let sid = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file) else { continue }
            // Per-file tolerance: a single field with a wrong type or an
            // unknown `permissionMode` raw value must not blank out the
            // entire session's metadata (title, isPinned, model, ...).
            // If the JSON is structurally broken we still fall back to
            // an empty Meta, but if it's well-formed we keep whatever
            // we can decode.
            guard let meta = Self.decodeTolerant(data) else { continue }
            result[sid] = meta
        }
        cache.merge(result) { _, new in new }
        return result
    }

    /// Decode a `Meta` from JSON, tolerating per-field failures.
    ///
    /// Forward-compat strategy: as the schema evolves (new fields,
    /// `PermissionMode` gaining cases, date format changes, etc.), a
    /// single bad field would otherwise cascade into an empty Meta
    /// because `try? decoder.decode(Meta.self, ...)` discards the whole
    /// value. Instead, we decode into a generic dictionary and pull out
    /// each field with `decodeIfPresent`, so a corrupt or unknown value
    /// in one place does not erase the others.
    private static func decodeTolerant(_ data: Data) -> Meta? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode([String: AnyCodableValue].self, from: data) else {
            return nil
        }
        return Meta(
            title: raw["title"]?.stringValue,
            isPinned: raw["isPinned"]?.boolValue ?? false,
            model: raw["model"]?.stringValue,
            effort: raw["effort"]?.stringValue,
            permissionMode: raw["permissionMode"].flatMap { $0.stringValue.flatMap(PermissionMode.init(rawValue:)) },
            updatedAt: raw["updatedAt"]?.dateValue
        )
    }

    private func fileURL(for sessionId: String) -> URL {
        baseURL.appendingPathComponent("\(sessionId).json")
    }
}

/// Minimal `Sendable` value type that can hold any JSON scalar or
/// array/dict. Lets us decode the on-disk JSON into a permissive
/// intermediate representation so `SessionMetaStore.decodeTolerant`
/// can pull out individual fields without one bad field collapsing
/// the whole decode.
private enum AnyCodableValue: Decodable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([AnyCodableValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: AnyCodableValue].self) { self = .object(v); return }
        self = .null
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var dateValue: Date? {
        if case .string(let s) = self {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }
}
