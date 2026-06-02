# Usage Provider / Adapter Architecture

**Date:** 2026-06-02

## Problem

The current `RateLimitService` only supports the Anthropic oauth/usage endpoint, with a thin custom-endpoint escape hatch (UserDefaults keys `usageEndpoint`, `usageEndpointBearerToken`, `usageEndpointFiveHourPath`, `usageEndpointSevenDayPath`). The custom-endpoint feature hardcodes Anthropic-shaped JSON paths (`five_hour.utilization` / `seven_day.utilization`) and cannot parse:

- Array indexing: `arr[0].value`, `arr.0.value`
- Provider-specific response shapes (e.g. MiniMax's `model_remains[].current_*_remaining_percent` with inversion semantics)
- Reset times from non-Anthropic providers

Setting up a non-Anthropic usage source today requires manually figuring out the JSON path and accepting that some fields (reset times) cannot be parsed.

## Goal

Add a multi-provider usage query system that supports Anthropic, MiniMax, OpenAI (alias for Custom with Anthropic defaults), and Custom. Hide provider-specific configuration behind a single `UsageProvider` picker in Settings, and add a "Test Endpoint" debug action that shows HTTP status, raw JSON, and parsed result.

Constraints:
- Existing Anthropic configurations must keep working without re-setup (backward-compatible migration).
- `RateLimitUsage` (the model used by `ClarcChatKit`) is **not** changed — adapters convert to it at the boundary.
- Anthropic OAuth / Keychain / refresh logic stays in `RateLimitService` (not pushed into the Anthropic adapter).

## Non-Goals

- A real OpenAI `/v1/usage` integration. "OpenAI" provider is a UX alias for Custom with Anthropic-shaped default paths.
- Adapters for additional providers (e.g. Gemini, Bedrock). Adding a new provider is a drop-in `UsageAdapter` conformance, but none are scheduled.
- A general-purpose JSON path DSL. The path parser is scoped to what the spec'd adapters need.

## Architecture

### Module Layout

New `ClarcCore/Usage/` subsystem (ClarcCore has no UI dependencies, so the adapter layer lives there):

```
Packages/Sources/ClarcCore/Usage/
  UsageProvider.swift     // enum + Codable + default config helpers
  UsageQueryConfig.swift  // immutable request config struct
  UsageAdapter.swift      // protocol + UsageError + UsageFetchOutcome + factory
  JSONPath.swift          // enhanced path parser (a.b.c / a.0.b / a[0].b / [@k=v])
  AnthropicAdapter.swift
  MiniMaxAdapter.swift
  OpenAIAdapter.swift     // thin wrapper over CustomAdapter
  CustomAdapter.swift
```

`Clarc/Services/RateLimitService.swift` shrinks from ~320 lines to ~80. It now only:
1. Pulls a `UsageQueryConfig` together from `AppState` + provider defaults.
2. Resolves the OAuth access token for the Anthropic path (Keychain read, optional refresh).
3. Calls the factory-built adapter.
4. Caches the result (5-minute TTL) and the `authFailed` flag (Anthropic only).

`Clarc/App/AppState.swift` gains one new computed property (`usageProvider`) and a one-shot migration.

`Clarc/Views/SettingsView.swift`'s `usageEndpointSection` is rewritten to a Picker-driven layout with conditional fields and a "Test Endpoint" sheet.

### Data Model

`UsageProvider` enum (Codable, persisted as raw string in UserDefaults):

```swift
public enum UsageProvider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case minimax
    case openai
    case custom
}
```

`UsageProvider` exposes static default values for the four fields the UI pre-fills:

| provider   | endpoint                                                  | 5h path                                              | 7d path                                              |
|------------|-----------------------------------------------------------|------------------------------------------------------|------------------------------------------------------|
| `anthropic`| `https://api.anthropic.com/api/oauth/usage` (built-in)    | `five_hour.utilization`                              | `seven_day.utilization`                              |
| `minimax`  | `https://www.minimaxi.com/v1/token_plan/remains`          | n/a (parsed internally)                              | n/a (parsed internally)                              |
| `openai`   | (empty, user fills)                                       | `five_hour.utilization`                              | `seven_day.utilization`                              |
| `custom`   | (empty, user fills)                                       | (empty, user fills)                                  | (empty, user fills)                                  |

### Query Config

```swift
public struct UsageQueryConfig: Sendable {
    public let provider: UsageProvider
    public let endpoint: String?        // nil → provider built-in
    public let bearerToken: String?     // nil / empty → no Authorization header
    public let fiveHourPath: String?    // nil → provider default
    public let sevenDayPath: String?    // nil → provider default
}
```

Config is reconstructed on each call (no caching). It is the only thing `RateLimitService` hands to the adapter factory.

### Adapter Protocol

```swift
public enum UsageError: Error, Sendable {
    case http(status: Int, body: Data)
    case invalidURL
    case malformedJSON
    case missingField(String)            // e.g. "model_remains[].current_interval_remaining_percent"
    case numericOutOfRange(field: String, value: Double)
}

public struct UsageFetchOutcome: Sendable {
    public let usage: RateLimitUsage      // 5h/7d are utilization (0-100), already inverted if necessary
    public let rawJSON: Data              // captured for the Test Endpoint sheet
    public let httpStatus: Int
    public let endpointURL: String
}

public protocol UsageAdapter: Sendable {
    func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome
}

public enum UsageAdapterFactory {
    public static func make(provider: UsageProvider) -> any UsageAdapter
}
```

Boundary rule: adapters always return **utilization** (0-100, inverted if the source is "remaining"). The caller never sees remaining/utilization semantics — MiniMax's `100 - remaining` lives entirely inside `MiniMaxAdapter`.

### Adapter Implementations

**`AnthropicAdapter`**
- Endpoint: built-in `https://api.anthropic.com/api/oauth/usage`
- Sends `anthropic-beta: oauth-2025-04-20` header
- Sends `Authorization: Bearer <token>` (token prepared by `RateLimitService` from Keychain)
- Parses `five_hour.utilization`, `seven_day.utilization` (numeric)
- Parses `five_hour.resets_at`, `seven_day.resets_at` (ISO8601 string, with or without fractional seconds) → `Date?`
- 401 → `UsageError.http(401, body)`; `RateLimitService` flips `authFailed = true` on 401
- Ignores `fiveHourPath` / `sevenDayPath` (Anthropic shape is fixed)

**`MiniMaxAdapter`**
- Endpoint: `https://www.minimaxi.com/v1/token_plan/remains` (default; user can override)
- Authorization: optional `Bearer` (most users leave it empty)
- Body:
  ```json
  {
    "model_remains": [
      {
        "model_name": "general",
        "current_interval_remaining_percent": 98,
        "current_weekly_remaining_percent": 100,
        "end_time": 1748889600000,
        "weekly_end_time": 1750108800000
      }
    ]
  }
  ```
- Selection rule: prefer `model_name == "general"`; if absent, use first element of `model_remains`.
- Field mapping:
  - `fiveHourPercent`  ←  `100 - current_interval_remaining_percent`
  - `sevenDayPercent`  ←  `100 - current_weekly_remaining_percent`
  - `fiveHourResetsAt` ←  `Date(timeIntervalSince1970: end_time / 1000)` (ms → s)
  - `sevenDayResetsAt` ←  `Date(timeIntervalSince1970: weekly_end_time / 1000)` (ms → s)
- If the chosen element is missing any of the four fields, throw `UsageError.missingField(<dot-path>)` for the first missing one. Reset times are optional → missing reset does NOT throw; `RateLimitUsage.resetsAt` is simply `nil`.
- The four required fields use `JSONPath` with `model_remains[@model_name=general].current_interval_remaining_percent` (predicate form). If `general` is absent, the adapter falls back to indexing `[0]` of the array.
- Numeric values are clamped to 0-100; out-of-range values log a warning but do not throw.
- The MiniMax response also carries `remains_time` / `weekly_remains_time` fields (countdown seconds). These are **not** used: `RateLimitUsage` stores absolute `Date?`, and synthesizing a `Date` from a server-side countdown introduces clock-skew ambiguity. The adapter reads only `end_time` / `weekly_end_time`; if those are missing, `*ResetsAt` is `nil` without warning.

**`OpenAIAdapter`**
- Forwards to `CustomAdapter` (same code path). The "OpenAI" label is a UX preset only — it pre-fills path fields with the Anthropic shape on first switch, since users typically route OpenAI's `/v1/usage` through a proxy that normalizes to Anthropic shape.
- Implementation: `OpenAIAdapter.fetch` calls `CustomAdapter().fetch(config:)` with no transformation.

**`CustomAdapter`**
- Endpoint and bearer from `config` (caller must supply).
- Parses `fiveHourPath` / `sevenDayPath` via `JSONPath.lookup`. Returns first numeric value found; non-numeric leaf → `UsageError.missingField(path)`.
- Does NOT send `anthropic-beta` header. 401 does NOT flip `authFailed`.
- Empty `Authorization` header is omitted entirely (not sent as `Bearer `).

### JSONPath

New `JSONPath` enum + parser in `ClarcCore/Usage/JSONPath.swift`:

```swift
public indirect enum JSONPath: Sendable, Equatable {
    case root
    case key(String, JSONPath)              // .a.b.c
    case index(Int, JSONPath)               // .0.b  or  [0].b
    case predicate(String, String, JSONPath) // [@k=v] — key, value, rest
}

public enum JSONValue: Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

public enum JSONPathParser {
    public static func parse(_ source: String) throws -> JSONPath
}

extension JSONPath {
    public func lookup(in root: JSONValue) -> JSONValue?
}
```

Supported syntax:
- `a.b.c` — dictionary descent (existing behavior)
- `a.0.b` — array indexing via dot-number
- `a[0].b` — array indexing via brackets
- `a[@k=v].x` — array predicate: select first element whose `k` field equals `v`. Quoted strings in v use `"…"`.

Parser is hand-written (no regex). Errors throw a typed `JSONPathParseError` with the offending segment index. No leading `$.` is required (root is implicit).

For the spec'd adapters the predicate form is only used by `MiniMaxAdapter`. The Custom adapter never needs it.

### Service Layer

`RateLimitService` (rewritten, behavior-preserving for Anthropic):

```swift
func fetchUsage(forceRefresh: Bool = false) async -> RateLimitUsage? {
    if !forceRefresh, let c = cached, let at = cachedAt, Date().timeIntervalSince(at) < cacheTTL {
        return c
    }

    let config = makeConfig()                   // reads AppState + provider defaults
    let resolvedConfig = await resolveAuth(for: config)  // injects OAuth for Anthropic

    do {
        let outcome = try await UsageAdapterFactory
            .make(provider: config.provider)
            .fetch(config: resolvedConfig)
        cached = outcome.usage
        cachedAt = Date()
        authFailed = false
        return outcome.usage
    } catch UsageError.http(401, _) where config.provider == .anthropic {
        authFailed = true
        return cached
    } catch {
        return cached
    }
}
```

OAuth injection for Anthropic:
1. Read `claudeAiOauth` from Keychain service `Claude Code-credentials`.
2. If `expiresAt` is within 30 s of now, attempt refresh against `https://api.anthropic.com/api/oauth/token`. On success, use new token; on failure, fall through to old token (existing behavior).
3. Set `config.bearerToken = accessToken`. Other providers ignore `bearerToken` (Anthropic uses it; MiniMax uses whatever the user typed; Custom/Custom-shaped use whatever the user typed).

### AppState

New computed property:

```swift
var usageProvider: UsageProvider {
    get { UserDefaults.standard.string(forKey: "usageProvider").flatMap(UsageProvider.init(rawValue:)) ?? .anthropic }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "usageProvider") }
}
```

The four existing `usageEndpoint*` properties are kept verbatim. Their semantics: when non-nil/non-empty they override the provider default. The new picker UI sets/clears them on switch.

Migration (one-shot, runs in `AppState.init`):

```swift
private static let didMigrateUsageProviderKey = "usageProviderMigrated"

private func migrateUsageProvider() {
    guard !UserDefaults.standard.bool(forKey: Self.didMigrateUsageProviderKey) else { return }
    defer { UserDefaults.standard.set(true, forKey: Self.didMigrateUsageProviderKey) }
    if usageProvider == .anthropic,                  // i.e. key unset, default applies
       let ep = usageEndpoint, !ep.isEmpty {
        usageProvider = .custom                     // legacy custom-endpoint users
    }
}
```

The migration flag ensures it runs exactly once. After first launch the migration is a no-op, and the user's `usageEndpoint*` keys continue to work because the UI binds them through the same computed properties.

### UI

`GeneralSettingsTab.usageEndpointSection` is replaced with:

```
[Usage Endpoint]
[Provider]                Picker: Anthropic / MiniMax / OpenAI / Custom
[provider help text]

[Endpoint URL]            always shown; disabled for Anthropic
[Bearer Token]            always shown; disabled for Anthropic (shows "OAuth")

when provider ∈ {anthropic, openai, custom}:
  [5h JSON Path]
  [7d JSON Path]
when provider == minimax:
  (small caption: "MiniMax provider automatically parses model_remains fields. No JSON path required.")

[Test Endpoint]           always shown, triggers sheet
```

A new `@MainActor @Observable` `UsageSettingsViewModel` is introduced (file-scope in `SettingsView.swift`, private):

```swift
@MainActor @Observable
final class UsageSettingsViewModel {
    enum TestState {
        case idle
        case running
        case success(http: Int, usage: RateLimitUsage, rawJSON: Data, endpoint: String)
        case failure(http: Int?, message: String, rawJSON: Data?, endpoint: String)
    }
    var testState: TestState = .idle

    func test(appState: AppState) async { ... }
}
```

On provider switch, the view calls `applyProviderDefaults(_:)` which:
- For `openai`: pre-fills the two path fields with the Anthropic defaults **only** if both are currently empty.
- For `minimax`: pre-fills the endpoint with the official URL **only** if currently empty.
- For `anthropic`: clears the user-typed path overrides (so the next Anthropic fetch uses the built-in defaults) and disables the path text fields in the UI.
- For `custom`: no auto-fill.

Pre-fill never overwrites a value the user has already typed. Pre-fill is idempotent: switching to `openai` and back to `custom` does not erase the user's `custom` paths.

`TestEndpointSheet` (separate `View` in the same file) renders `viewModel.testState`:

```
[Test Result]                                                       [Close]

[OK] HTTP 200       or       [Error] HTTP 401   /   Network error

5h Utilization:   2%
7d Utilization:   0%
Resets:           in 4h 32m    /    in 6d 18h   (only if resetsAt is non-nil)

[Raw Response]                                  [Copy]
  [monospaced, scrollable, JSON pretty-printed]
```

On failure paths the raw JSON area shows whatever body the server returned (or the localized error description if no body). The Copy button places pretty JSON on the pasteboard.

### Backward Compatibility

- Anthropic users: no settings change. The provider defaults match the current hardcoded behavior, OAuth flow is unchanged, `RateLimitUsage` fields are unchanged.
- Existing custom-endpoint users: migration sets `usageProvider = .custom` on first launch. Their `usageEndpoint`, `usageEndpointBearerToken`, `usageEndpointFiveHourPath`, `usageEndpointSevenDayPath` continue to work — the path defaults resolve to whatever the user typed (or Anthropic shape when nil). Behavior is bit-for-bit identical to today for the existing JSON path syntax (`a.b.c`).
- `RateLimitUsage` is unchanged. `bridge.fetchRateLimitHandler` keeps its `() async -> RateLimitUsage?` shape.

## File Changes

New:
- `Packages/Sources/ClarcCore/Usage/UsageProvider.swift`
- `Packages/Sources/ClarcCore/Usage/UsageQueryConfig.swift`
- `Packages/Sources/ClarcCore/Usage/UsageAdapter.swift` (protocol + factory + `UsageError` + `UsageFetchOutcome`)
- `Packages/Sources/ClarcCore/Usage/JSONPath.swift` (parser + lookup + `JSONValue` enum)
- `Packages/Sources/ClarcCore/Usage/AnthropicAdapter.swift`
- `Packages/Sources/ClarcCore/Usage/MiniMaxAdapter.swift`
- `Packages/Sources/ClarcCore/Usage/OpenAIAdapter.swift`
- `Packages/Sources/ClarcCore/Usage/CustomAdapter.swift`

Modified:
- `Clarc/Services/RateLimitService.swift` (rewrite — shrinks from ~320 lines to ~80)
- `Clarc/App/AppState.swift` (add `usageProvider`, `migrateUsageProvider()`, gate OAuth path on `provider == .anthropic`; existing `usageEndpoint*` properties unchanged)
- `Clarc/Views/SettingsView.swift` (rewrite `usageEndpointSection`; add `UsageSettingsViewModel` and `TestEndpointSheet`)

## Testing

No test suite exists in this project (per CLAUDE.md). The Test Endpoint sheet is the primary user-facing verification surface: it shows HTTP status, raw JSON, and parsed `RateLimitUsage` for any provider/endpoint combination. Manual verification matrix (each cell at least once after build):

| provider   | endpoint                                                | bearer | expected parse |
|------------|---------------------------------------------------------|--------|----------------|
| `anthropic`| default (OAuth)                                         | OAuth  | 5h/7d from `five_hour` / `seven_day` |
| `minimax`  | default                                                 | empty  | 5h = 100 - interval_remaining, 7d = 100 - weekly_remaining |
| `minimax`  | default, response has no `general` element              | empty  | first element used, same math |
| `openai`   | user-typed Anthropic-shape proxy                        | typed  | 5h/7d from `five_hour` / `seven_day` |
| `custom`   | user-typed MiniMax-shape proxy                          | typed  | values from user-typed paths |
| `custom`   | user-typed 401 endpoint                                 | typed  | failure sheet, raw body shown |
| `custom`   | user-typed URL returning `arr[0].value`                 | typed  | numeric leaf returned |

## Open Items

- None. The MiniMax official endpoint (`https://www.minimaxi.com/v1/token_plan/remains`) was confirmed by the user and is hardcoded as the MiniMax default.
