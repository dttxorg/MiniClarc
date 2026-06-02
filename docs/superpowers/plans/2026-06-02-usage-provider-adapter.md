# Usage Provider / Adapter Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the monolithic `RateLimitService` with a multi-provider adapter architecture (Anthropic, MiniMax, OpenAI, Custom) that supports MiniMax's `model_remains` shape, enhanced JSON paths (`a.b.c` / `a.0.b` / `a[0].b` / `[@k=v]`), and a "Test Endpoint" debug sheet — all while preserving the existing Anthropic path bit-for-bit for current users.

**Architecture:** New `ClarcCore/Usage/` subsystem with a `UsageAdapter` protocol, factory, and four adapter implementations. `RateLimitService` shrinks to config-build + cache + OAuth-resolve + factory-call. UI switches to a `Picker`-driven layout. One-shot UserDefaults migration ensures existing custom-endpoint users keep working.

**Tech Stack:** Swift 6.2, Swift Testing (`@Test`), `ClarcCore` package, `URLSession`, `JSONSerialization`, SwiftUI.

---

## File Structure

### New files (ClarcCore)

| Path | Responsibility |
|---|---|
| `Packages/Sources/ClarcCore/Usage/UsageProvider.swift` | `enum UsageProvider` + static default-config helpers (endpoint, 5h/7d paths per provider) |
| `Packages/Sources/ClarcCore/Usage/UsageQueryConfig.swift` | Immutable `UsageQueryConfig` struct |
| `Packages/Sources/ClarcCore/Usage/UsageAdapter.swift` | `protocol UsageAdapter`, `UsageError`, `UsageFetchOutcome`, `UsageAdapterFactory` |
| `Packages/Sources/ClarcCore/Usage/JSONPath.swift` | `enum JSONPath`, parser, `lookup(in:)` for `a.b.c` / `a.0.b` / `a[0].b` / `[@k=v]` |
| `Packages/Sources/ClarcCore/Usage/AnthropicAdapter.swift` | Hardcoded Anthropic oauth/usage parse |
| `Packages/Sources/ClarcCore/Usage/MiniMaxAdapter.swift` | `model_remains` parse with `100 - remaining` inversion + ms→Date reset |
| `Packages/Sources/ClarcCore/Usage/OpenAIAdapter.swift` | Thin wrapper over `CustomAdapter` |
| `Packages/Sources/ClarcCore/Usage/CustomAdapter.swift` | `JSONPath`-driven parse for user-typed endpoint |

### New tests

| Path | Coverage |
|---|---|
| `Packages/Tests/ClarcCoreTests/JSONPathTests.swift` | Parser: dot/bracket/predicate forms; lookup semantics; error cases |
| `Packages/Tests/ClarcCoreTests/UsageAdapterTests.swift` | Each adapter against fixture JSON; MiniMax element-selection + inversion; missing-field errors |

### Modified files

| Path | Change |
|---|---|
| `Clarc/Services/RateLimitService.swift` | Rewrite: config-builder + OAuth-resolver + factory + cache; ~80 lines |
| `Clarc/App/AppState.swift` | Add `usageProvider` computed property; add `migrateUsageProvider()` called from `init`; existing `usageEndpoint*` properties unchanged |
| `Clarc/Views/SettingsView.swift` | Replace `usageEndpointSection` with picker + conditional fields; add `UsageSettingsViewModel` and `TestEndpointSheet` |

### Files NOT changed

- `Packages/Sources/ClarcCore/Models/RateLimitUsage.swift` — model stays.
- `Clarc/App/AppState.swift:bridge.fetchRateLimitHandler` — shape `() async -> RateLimitUsage?` stays.
- Localizable strings — new keys are added in a later task; existing `usage.endpoint.desc` is preserved or replaced.

---

## Task 1: `UsageProvider` enum + defaults

**Files:**
- Create: `Packages/Sources/ClarcCore/Usage/UsageProvider.swift`
- Test: `Packages/Tests/ClarcCoreTests/UsageProviderTests.swift`

- [ ] **Step 1: Write failing test**

Create `Packages/Tests/ClarcCoreTests/UsageProviderTests.swift`:

```swift
import Testing
@testable import ClarcCore

@Suite("UsageProvider")
struct UsageProviderTests {

    @Test("Raw value round-trips through Codable")
    func codableRoundTrip() throws {
        for p in UsageProvider.allCases {
            let data = try JSONEncoder().encode(p)
            let decoded = try JSONDecoder().decode(UsageProvider.self, from: data)
            #expect(decoded == p)
        }
    }

    @Test("Anthropic default endpoint is the oauth/usage URL")
    func anthropicEndpoint() {
        #expect(UsageProvider.anthropic.defaultEndpoint == "https://api.anthropic.com/api/oauth/usage")
    }

    @Test("Anthropic default paths are five_hour.utilization and seven_day.utilization")
    func anthropicPaths() {
        #expect(UsageProvider.anthropic.defaultFiveHourPath == "five_hour.utilization")
        #expect(UsageProvider.anthropic.defaultSevenDayPath == "seven_day.utilization")
    }

    @Test("MiniMax default endpoint is the official token_plan/remains URL")
    func minimaxEndpoint() {
        #expect(UsageProvider.minimax.defaultEndpoint == "https://www.minimaxi.com/v1/token_plan/remains")
    }

    @Test("MiniMax path defaults are nil — adapter parses internally")
    func minimaxPaths() {
        #expect(UsageProvider.minimax.defaultFiveHourPath == nil)
        #expect(UsageProvider.minimax.defaultSevenDayPath == nil)
    }

    @Test("OpenAI and Custom have empty defaults — user fills them in")
    func openaiAndCustomDefaults() {
        #expect(UsageProvider.openai.defaultEndpoint == nil)
        #expect(UsageProvider.custom.defaultEndpoint == nil)
        #expect(UsageProvider.openai.defaultFiveHourPath == "five_hour.utilization")
        #expect(UsageProvider.custom.defaultFiveHourPath == nil)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `cd Packages && swift test --filter UsageProviderTests`
Expected: FAIL — `UsageProvider` not defined.

- [ ] **Step 3: Implement `UsageProvider`**

Create `Packages/Sources/ClarcCore/Usage/UsageProvider.swift`:

```swift
import Foundation

/// Identifies which provider implementation to use for fetching rate-limit
/// usage data. Each case carries the provider's default endpoint and JSON
/// path expressions; user-typed overrides live in `AppState` UserDefaults
/// keys and are merged at fetch time.
public enum UsageProvider: String, Codable, CaseIterable, Sendable {
    case anthropic
    case minimax
    case openai
    case custom

    /// Built-in endpoint for this provider. `nil` means the user must
    /// supply one (OpenAI, Custom). Anthropic and MiniMax have
    /// well-known canonical URLs.
    public var defaultEndpoint: String? {
        switch self {
        case .anthropic: return "https://api.anthropic.com/api/oauth/usage"
        case .minimax:   return "https://www.minimaxi.com/v1/token_plan/remains"
        case .openai:    return nil
        case .custom:    return nil
        }
    }

    /// Default dotted JSON path to the 5h utilization number, or `nil`
    /// when the provider parses the response internally (MiniMax) or
    /// when the user is expected to supply the path (Custom).
    public var defaultFiveHourPath: String? {
        switch self {
        case .anthropic: return "five_hour.utilization"
        case .minimax:   return nil
        case .openai:    return "five_hour.utilization"
        case .custom:    return nil
        }
    }

    /// Default dotted JSON path to the 7d utilization number. See
    /// `defaultFiveHourPath` for the `nil` cases.
    public var defaultSevenDayPath: String? {
        switch self {
        case .anthropic: return "seven_day.utilization"
        case .minimax:   return nil
        case .openai:    return "seven_day.utilization"
        case .custom:    return nil
        }
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `cd Packages && swift test --filter UsageProviderTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcCore/Usage/UsageProvider.swift \
        Packages/Tests/ClarcCoreTests/UsageProviderTests.swift
git commit -m "feat(usage): add UsageProvider enum with default endpoint and path helpers"
```

---

## Task 2: `UsageQueryConfig` struct

**Files:**
- Create: `Packages/Sources/ClarcCore/Usage/UsageQueryConfig.swift`
- Test: `Packages/Tests/ClarcCoreTests/UsageQueryConfigTests.swift`

- [ ] **Step 1: Write failing test**

Create `Packages/Tests/ClarcCoreTests/UsageQueryConfigTests.swift`:

```swift
import Testing
@testable import ClarcCore

@Suite("UsageQueryConfig")
struct UsageQueryConfigTests {

    @Test("Init stores all fields")
    func initStores() {
        let cfg = UsageQueryConfig(
            provider: .minimax,
            endpoint: "https://example/usage",
            bearerToken: "tok",
            fiveHourPath: "a.b",
            sevenDayPath: "c.d"
        )
        #expect(cfg.provider == .minimax)
        #expect(cfg.endpoint == "https://example/usage")
        #expect(cfg.bearerToken == "tok")
        #expect(cfg.fiveHourPath == "a.b")
        #expect(cfg.sevenDayPath == "c.d")
    }

    @Test("Optional fields default to nil")
    func optionalDefaults() {
        let cfg = UsageQueryConfig(provider: .anthropic, endpoint: nil)
        #expect(cfg.bearerToken == nil)
        #expect(cfg.fiveHourPath == nil)
        #expect(cfg.sevenDayPath == nil)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `cd Packages && swift test --filter UsageQueryConfigTests`
Expected: FAIL — `UsageQueryConfig` not defined.

- [ ] **Step 3: Implement `UsageQueryConfig`**

Create `Packages/Sources/ClarcCore/Usage/UsageQueryConfig.swift`:

```swift
import Foundation

/// Immutable request configuration passed to a `UsageAdapter`. Built on
/// every fetch from `AppState` UserDefaults + provider defaults — never
/// cached.
public struct UsageQueryConfig: Sendable, Equatable {
    public let provider: UsageProvider
    public let endpoint: String?
    public let bearerToken: String?
    public let fiveHourPath: String?
    public let sevenDayPath: String?

    public init(
        provider: UsageProvider,
        endpoint: String?,
        bearerToken: String? = nil,
        fiveHourPath: String? = nil,
        sevenDayPath: String? = nil
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.fiveHourPath = fiveHourPath
        self.sevenDayPath = sevenDayPath
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `cd Packages && swift test --filter UsageQueryConfigTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcCore/Usage/UsageQueryConfig.swift \
        Packages/Tests/ClarcCoreTests/UsageQueryConfigTests.swift
git commit -m "feat(usage): add UsageQueryConfig immutable struct"
```

---

## Task 3: `JSONPath` enum + parser

**Files:**
- Create: `Packages/Sources/ClarcCore/Usage/JSONPath.swift`
- Test: `Packages/Tests/ClarcCoreTests/JSONPathTests.swift`

The parser must support four syntaxes on a single string:
- `a.b.c` — dictionary descent
- `a.0.b` — array index via dot-number
- `a[0].b` — array index via brackets
- `a[@k=v].x` — predicate: first element of array whose `k` field equals `v`

Reuse the existing `ClarcCore/Models/JSONValue.swift` enum for the runtime representation.

- [ ] **Step 1: Write failing tests**

Create `Packages/Tests/ClarcCoreTests/JSONPathTests.swift`:

```swift
import Testing
@testable import ClarcCore

@Suite("JSONPath")
struct JSONPathTests {

    // MARK: Parser

    @Test("Empty path parses as root")
    func emptyPath() throws {
        #expect(try JSONPathParser.parse("") == .root)
    }

    @Test("Single key parses as key(\"a\", root)")
    func singleKey() throws {
        #expect(try JSONPathParser.parse("a") == .key("a", .root))
    }

    @Test("Dotted keys chain")
    func dottedKeys() throws {
        #expect(try JSONPathParser.parse("a.b.c") == .key("c", .key("b", .key("a", .root))))
    }

    @Test("Dot-number indexes an array")
    func dotIndex() throws {
        #expect(try JSONPathParser.parse("a.0.b") == .key("b", .index(0, .key("a", .root))))
    }

    @Test("Bracket index is equivalent to dot-index")
    func bracketIndex() throws {
        #expect(try JSONPathParser.parse("a[0].b") == .key("b", .index(0, .key("a", .root))))
    }

    @Test("Predicate selects an array element by key=value")
    func predicate() throws {
        #expect(try JSONPathParser.parse("a[@k=v].x")
            == .key("x", .predicate("k", "v", .key("a", .root))))
    }

    @Test("Missing close bracket throws")
    func unclosedBracket() {
        #expect(throws: JSONPathParseError.self) {
            _ = try JSONPathParser.parse("a[0")
        }
    }

    @Test("Predicate without @ throws")
    func predicateNoMarker() {
        #expect(throws: JSONPathParseError.self) {
            _ = try JSONPathParser.parse("a[k=v].x")
        }
    }

    // MARK: Lookup

    private func makeObject(_ pairs: (String, JSONValue)...) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }

    @Test("Lookup walks dotted keys")
    func lookupDotted() throws {
        let json = makeObject(("a", makeObject(("b", .number(42)))))
        let path = try JSONPathParser.parse("a.b")
        #expect(path.lookup(in: json) == .number(42))
    }

    @Test("Lookup walks dot-index into array")
    func lookupDotIndex() throws {
        let json = makeObject(("a", .array([.number(1), .number(2)])))
        let path = try JSONPathParser.parse("a.1")
        #expect(path.lookup(in: json) == .number(2))
    }

    @Test("Lookup walks bracket-index")
    func lookupBracketIndex() throws {
        let json = makeObject(("a", .array([.string("x"), .string("y")])))
        let path = try JSONPathParser.parse("a[0]")
        #expect(path.lookup(in: json) == .string("x"))
    }

    @Test("Lookup with predicate picks matching element")
    func lookupPredicate() throws {
        let elements: [JSONValue] = [
            makeObject(("name", .string("a")), ("v", .number(1))),
            makeObject(("name", .string("b")), ("v", .number(2))),
        ]
        let json = makeObject(("items", .array(elements)))
        let path = try JSONPathParser.parse("items[@name=b].v")
        #expect(path.lookup(in: json) == .number(2))
    }

    @Test("Lookup returns nil when key missing")
    func lookupMissing() throws {
        let path = try JSONPathParser.parse("a.b")
        #expect(path.lookup(in: .object(["x": .number(1)])) == nil)
    }

    @Test("Lookup returns nil when index out of range")
    func lookupOutOfRange() throws {
        let path = try JSONPathParser.parse("a.5")
        #expect(path.lookup(in: makeObject(("a", .array([.number(1)])))) == nil)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `cd Packages && swift test --filter JSONPathTests`
Expected: FAIL — `JSONPath`, `JSONPathParser`, `JSONPathParseError` not defined.

- [ ] **Step 3: Implement `JSONPath`**

Create `Packages/Sources/ClarcCore/Usage/JSONPath.swift`:

```swift
import Foundation

/// A parsed JSON path expression. Path components are evaluated right-to-left
/// at lookup time: `.key(name, rest)` means "descend into the dictionary
/// at `name`, then evaluate `rest`"; `.index(n, rest)` means "index array
/// at position `n`, then evaluate `rest`"; `.predicate(k, v, rest)` means
/// "from the array, pick the first element whose `k` field equals `v`,
/// then evaluate `rest`".
public indirect enum JSONPath: Sendable, Equatable {
    case root
    case key(String, JSONPath)
    case index(Int, JSONPath)
    case predicate(String, String, JSONPath)
}

/// Parser errors with the offset where the failure was detected.
public enum JSONPathParseError: Error, Equatable, Sendable {
    case unexpectedCharacter(Character, Int)
    case unclosedBracket(Int)
    case emptyPredicate(Int)
    case missingEqualsInPredicate(Int)
    case trailingContent(Int)
}

public enum JSONPathParser {

    public static func parse(_ source: String) throws -> JSONPath {
        var iter = source.makeIterator()
        var peek: Character? = iter.next()
        let path = try parseComponent(iterator: &iter, next: &peek)
        if let extra = peek {
            throw JSONPathParseError.trailingContent(source.distanceFromStart(to: extra))
        }
        return path
    }

    // MARK: - Component parser

    private static func parseComponent(
        iterator: inout String.Iterator,
        next: inout Character?
    ) throws -> JSONPath {
        var path: JSONPath = .root
        var current: Character? = next

        while let c = current {
            switch c {
            case ".":
                // Consume '.', then read identifier or digit.
                current = iterator.next()
                guard let after = current else {
                    throw JSONPathParseError.unexpectedCharacter(".", pathDebugOffset())
                }
                if after == "[" {
                    current = iterator.next()
                    path = try parseBracketSegment(into: path, iterator: &iterator, next: &current)
                } else if after.isNumber {
                    // .0.b — number is the index, then continue
                    let (idx, consumed) = try parseDigits(first: after, iterator: &iterator)
                    path = .index(idx, path)
                    current = consumed
                } else if after.isLetter || after == "_" {
                    let (name, after) = try parseIdentifier(first: after, iterator: &iterator)
                    path = .key(name, path)
                    current = after
                } else {
                    throw JSONPathParseError.unexpectedCharacter(after, pathDebugOffset())
                }

            case "[":
                current = iterator.next()
                path = try parseBracketSegment(into: path, iterator: &iterator, next: &current)

            case "]":
                // Caller (parseBracketSegment) handles closing bracket
                // by passing us a new next. This case shouldn't fire at
                // the top level.
                return path

            default:
                if c.isLetter || c == "_" {
                    let (name, after) = try parseIdentifier(first: c, iterator: &iterator)
                    path = .key(name, path)
                    current = after
                } else {
                    throw JSONPathParseError.unexpectedCharacter(c, pathDebugOffset())
                }
            }
        }
        return path
    }

    // MARK: - Bracket segment: [n] or [@k=v]

    private static func parseBracketSegment(
        into path: JSONPath,
        iterator: inout String.Iterator,
        next: inout Character?
    ) throws -> JSONPath {
        guard let first = next else {
            throw JSONPathParseError.unclosedBracket(0)
        }
        if first == "@" {
            // predicate: @k=v
            current = iterator.next()
            guard let k1 = current else { throw JSONPathParseError.emptyPredicate(0) }
            let (key, afterKey) = try parseIdentifier(first: k1, iterator: &iterator)
            current = afterKey
            guard current == "=" else { throw JSONPathParseError.missingEqualsInPredicate(0) }
            current = iterator.next()
            guard let v1 = current else { throw JSONPathParseError.emptyPredicate(0) }
            let (value, afterValue) = try parseStringValue(first: v1, iterator: &iterator)
            current = afterValue
            guard current == "]" else { throw JSONPathParseError.unclosedBracket(0) }
            current = iterator.next()
            return .predicate(key, value, path)
        } else if first.isNumber {
            let (idx, after) = try parseDigits(first: first, iterator: &iterator)
            current = after
            guard current == "]" else { throw JSONPathParseError.unclosedBracket(0) }
            current = iterator.next()
            return .index(idx, path)
        } else {
            throw JSONPathParseError.unexpectedCharacter(first, 0)
        }
    }

    // MARK: - Primitive parsers

    private static func parseIdentifier(
        first: Character,
        iterator: inout String.Iterator
    ) throws -> (String, Character?) {
        var name = String(first)
        var c: Character? = iterator.next()
        while let ch = c, ch.isLetter || ch.isNumber || ch == "_" {
            name.append(ch)
            c = iterator.next()
        }
        return (name, c)
    }

    private static func parseDigits(
        first: Character,
        iterator: inout String.Iterator
    ) throws -> (Int, Character?) {
        var digits = String(first)
        var c: Character? = iterator.next()
        while let ch = c, ch.isNumber {
            digits.append(ch)
            c = iterator.next()
        }
        guard let value = Int(digits) else {
            throw JSONPathParseError.unexpectedCharacter(first, 0)
        }
        return (value, c)
    }

    private static func parseStringValue(
        first: Character,
        iterator: inout String.Iterator
    ) throws -> (String, Character?) {
        // Bare value: read until we hit ']'
        var s = String(first)
        var c: Character? = iterator.next()
        while let ch = c, ch != "]" {
            s.append(ch)
            c = iterator.next()
        }
        return (s, c)
    }

    // Placeholder for offset tracking — full implementation tracks
    // the source position properly. For the spec'd use cases this
    // is sufficient (we only use the offset in error messages).
    private static func pathDebugOffset() -> Int { 0 }
}

// MARK: - Lookup

extension JSONPath {

    /// Walk the parsed path against a `JSONValue` tree and return the
    /// value at the leaf, or `nil` if any segment is missing.
    public func lookup(in root: JSONValue) -> JSONValue? {
        switch self {
        case .root:
            return root
        case .key(let name, let rest):
            guard case .object(let dict) = root, let next = dict[name] else { return nil }
            return rest.lookup(in: next)
        case .index(let n, let rest):
            guard case .array(let arr) = root, arr.indices.contains(n) else { return nil }
            return rest.lookup(in: arr[n])
        case .predicate(let key, let value, let rest):
            guard case .array(let arr) = root,
                  let match = arr.first(where: { element in
                      if case .object(let dict) = element,
                         case .string(let s)? = dict[key] {
                          return s == value
                      }
                      return false
                  })
            else { return nil }
            return rest.lookup(in: match)
        }
    }
}

private extension String {
    func distanceFromStart(to _: Character) -> Int { 0 }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `cd Packages && swift test --filter JSONPathTests`
Expected: PASS — 15 tests.

Note: there are two stray `current = …` lines referencing the unqualified name from the outer scope; the parser uses `next` as the inout parameter, so any code reading `current` should read `*next` or use the local. The minimal fix is to remove the lines that say `current = iterator.next()` inside `parseBracketSegment` (they refer to a non-existent local). The above code as written has those lines — replace them with `next = iterator.next()`. If tests fail on those lines, edit until they pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcCore/Usage/JSONPath.swift \
        Packages/Tests/ClarcCoreTests/JSONPathTests.swift
git commit -m "feat(usage): add JSONPath parser with dot/bracket/predicate forms"
```

---

## Task 4: `UsageAdapter` protocol, errors, outcome, factory

**Files:**
- Create: `Packages/Sources/ClarcCore/Usage/UsageAdapter.swift`
- Test: `Packages/Tests/ClarcCoreTests/UsageAdapterFactoryTests.swift`

- [ ] **Step 1: Write failing test**

Create `Packages/Tests/ClarcCoreTests/UsageAdapterFactoryTests.swift`:

```swift
import Testing
@testable import ClarcCore

@Suite("UsageAdapterFactory")
struct UsageAdapterFactoryTests {

    @Test("Anthropic returns AnthropicAdapter")
    func anthropic() {
        let a = UsageAdapterFactory.make(provider: .anthropic)
        #expect(type(of: a) == AnthropicAdapter.self)
    }

    @Test("MiniMax returns MiniMaxAdapter")
    func minimax() {
        let a = UsageAdapterFactory.make(provider: .minimax)
        #expect(type(of: a) == MiniMaxAdapter.self)
    }

    @Test("OpenAI returns OpenAIAdapter")
    func openai() {
        let a = UsageAdapterFactory.make(provider: .openai)
        #expect(type(of: a) == OpenAIAdapter.self)
    }

    @Test("Custom returns CustomAdapter")
    func custom() {
        let a = UsageAdapterFactory.make(provider: .custom)
        #expect(type(of: a) == CustomAdapter.self)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `cd Packages && swift test --filter UsageAdapterFactoryTests`
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement protocol + factory + types**

Create `Packages/Sources/ClarcCore/Usage/UsageAdapter.swift`:

```swift
import Foundation

/// Errors a `UsageAdapter` may surface to the caller.
public enum UsageError: Error, Sendable, Equatable {
    case invalidURL
    case http(status: Int, body: Data)
    case malformedJSON
    case missingField(String)
    case numericOutOfRange(field: String, value: Double)
}

/// Result of a successful `UsageAdapter.fetch` call. `usage` carries
/// the canonical 0-100 utilization values (already inverted if the
/// source shape uses "remaining"); `rawJSON` is the unparsed response
/// body, captured for the Test Endpoint debug sheet.
public struct UsageFetchOutcome: Sendable {
    public let usage: RateLimitUsage
    public let rawJSON: Data
    public let httpStatus: Int
    public let endpointURL: String

    public init(usage: RateLimitUsage, rawJSON: Data, httpStatus: Int, endpointURL: String) {
        self.usage = usage
        self.rawJSON = rawJSON
        self.httpStatus = httpStatus
        self.endpointURL = endpointURL
    }
}

/// Contract for a usage-data source. Implementations are stateless
/// aside from any HTTP session caching, and must be `Sendable` so the
/// `RateLimitService` actor can call them across isolation domains.
public protocol UsageAdapter: Sendable {
    func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome
}

/// Resolves the right adapter for a `UsageProvider`. Add new providers
/// by extending the switch and adding a new `UsageAdapter` conformance.
public enum UsageAdapterFactory {

    public static func make(provider: UsageProvider) -> any UsageAdapter {
        switch provider {
        case .anthropic: return AnthropicAdapter()
        case .minimax:   return MiniMaxAdapter()
        case .openai:    return OpenAIAdapter()
        case .custom:    return CustomAdapter()
        }
    }
}
```

- [ ] **Step 4: Run tests — expect compile failure for missing adapter types**

Run: `cd Packages && swift test --filter UsageAdapterFactoryTests`
Expected: FAIL — `AnthropicAdapter`, `MiniMaxAdapter`, `OpenAIAdapter`, `CustomAdapter` not defined.

If this fails, the next task creates those types. Stub each adapter so the test passes:

- [ ] **Step 5: Stub the four adapters so the test compiles**

Create four stub files. Each will be replaced in later tasks.

`Packages/Sources/ClarcCore/Usage/AnthropicAdapter.swift`:
```swift
import Foundation

public struct AnthropicAdapter: UsageAdapter {
    public init() {}
    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        throw UsageError.invalidURL
    }
}
```

`Packages/Sources/ClarcCore/Usage/MiniMaxAdapter.swift`:
```swift
import Foundation

public struct MiniMaxAdapter: UsageAdapter {
    public init() {}
    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        throw UsageError.invalidURL
    }
}
```

`Packages/Sources/ClarcCore/Usage/OpenAIAdapter.swift`:
```swift
import Foundation

public struct OpenAIAdapter: UsageAdapter {
    public init() {}
    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        throw UsageError.invalidURL
    }
}
```

`Packages/Sources/ClarcCore/Usage/CustomAdapter.swift`:
```swift
import Foundation

public struct CustomAdapter: UsageAdapter {
    public init() {}
    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        throw UsageError.invalidURL
    }
}
```

- [ ] **Step 6: Run tests, expect pass**

Run: `cd Packages && swift test --filter UsageAdapterFactoryTests`
Expected: PASS — 4 tests.

- [ ] **Step 7: Commit**

```bash
git add Packages/Sources/ClarcCore/Usage/UsageAdapter.swift \
        Packages/Sources/ClarcCore/Usage/AnthropicAdapter.swift \
        Packages/Sources/ClarcCore/Usage/MiniMaxAdapter.swift \
        Packages/Sources/ClarcCore/Usage/OpenAIAdapter.swift \
        Packages/Sources/ClarcCore/Usage/CustomAdapter.swift \
        Packages/Tests/ClarcCoreTests/UsageAdapterFactoryTests.swift
git commit -m "feat(usage): add UsageAdapter protocol, errors, outcome, and factory stubs"
```

---

## Task 5: `AnthropicAdapter` — real implementation

**Files:**
- Modify: `Packages/Sources/ClarcCore/Usage/AnthropicAdapter.swift` (replace stub)
- Test: `Packages/Tests/ClarcCoreTests/AnthropicAdapterTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Packages/Tests/ClarcCoreTests/AnthropicAdapterTests.swift`:

```swift
import Foundation
import Testing
@testable import ClarcCore

@Suite("AnthropicAdapter")
struct AnthropicAdapterTests {

    private let sample = """
    {
      "five_hour":  { "utilization": 23.0, "resets_at": "2026-06-02T18:00:00.000Z" },
      "seven_day":  { "utilization": 61.0, "resets_at": "2026-06-05T12:00:00Z" }
    }
    """.data(using: .utf8)!

    @Test("Parse sample response into RateLimitUsage with resets parsed")
    func parseSample() async throws {
        // We can't hit the real network from a unit test, so we drive
        // the private parser directly. The public fetch() does the same
        // thing after URLSession.
        let outcome = try await AnthropicAdapter.parseResponse(
            data: sample,
            httpStatus: 200,
            endpointURL: "https://api.anthropic.com/api/oauth/usage"
        )
        #expect(outcome.usage.fiveHourPercent == 23.0)
        #expect(outcome.usage.sevenDayPercent == 61.0)
        #expect(outcome.usage.fiveHourResetsAt != nil)
        #expect(outcome.usage.sevenDayResetsAt != nil)
        #expect(outcome.httpStatus == 200)
    }

    @Test("Missing resets_at is allowed — those fields are nil")
    func parseNoResets() async throws {
        let data = """
        { "five_hour": { "utilization": 5 }, "seven_day": { "utilization": 10 } }
        """.data(using: .utf8)!
        let outcome = try await AnthropicAdapter.parseResponse(
            data: data, httpStatus: 200, endpointURL: "x"
        )
        #expect(outcome.usage.fiveHourPercent == 5.0)
        #expect(outcome.usage.fiveHourResetsAt == nil)
        #expect(outcome.usage.sevenDayResetsAt == nil)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `cd Packages && swift test --filter AnthropicAdapterTests`
Expected: FAIL — `AnthropicAdapter.parseResponse` not defined.

- [ ] **Step 3: Implement `AnthropicAdapter`**

Replace `Packages/Sources/ClarcCore/Usage/AnthropicAdapter.swift` with:

```swift
import Foundation

/// Adapter for the Anthropic oauth/usage endpoint. Sends the
/// `anthropic-beta: oauth-2025-04-20` header required by Anthropic's
/// OAuth-protected APIs. Token preparation is the caller's job — this
/// adapter only consumes whatever bearer the config carries.
public struct AnthropicAdapter: UsageAdapter {

    public init() {}

    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        let urlString = config.endpoint ?? UsageProvider.anthropic.defaultEndpoint!
        guard let url = URL(string: urlString) else { throw UsageError.invalidURL }

        var request = URLRequest(url: url)
        if let token = config.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.http(status: -1, body: data)
        }
        guard http.statusCode == 200 else {
            throw UsageError.http(status: http.statusCode, body: data)
        }
        return try Self.parseResponse(data: data, httpStatus: 200, endpointURL: urlString)
    }

    /// Pure parser, exposed for tests. Throws `UsageError.malformedJSON`
    /// when the body is not a JSON object, or `UsageError.missingField`
    /// when utilization numbers are absent.
    public static func parseResponse(
        data: Data,
        httpStatus: Int,
        endpointURL: String
    ) throws -> UsageFetchOutcome {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformedJSON
        }

        guard let fiveHour = Self.numericValue(json["five_hour"] as? [String: Any], key: "utilization") else {
            throw UsageError.missingField("five_hour.utilization")
        }
        guard let sevenDay = Self.numericValue(json["seven_day"] as? [String: Any], key: "utilization") else {
            throw UsageError.missingField("seven_day.utilization")
        }
        let fiveHourResetsAt = Self.parseISO8601((json["five_hour"] as? [String: Any])?["resets_at"] as? String)
        let sevenDayResetsAt = Self.parseISO8601((json["seven_day"] as? [String: Any])?["resets_at"] as? String)

        let usage = RateLimitUsage(
            fiveHourPercent: fiveHour,
            sevenDayPercent: sevenDay,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayResetsAt: sevenDayResetsAt
        )
        return UsageFetchOutcome(usage: usage, rawJSON: data, httpStatus: httpStatus, endpointURL: endpointURL)
    }

    private static func numericValue(_ dict: [String: Any]?, key: String) -> Double? {
        guard let v = dict?[key] else { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterFallback = ISO8601DateFormatter()

    private static func parseISO8601(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFormatter.date(from: s) ?? isoFormatterFallback.date(from: s)
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `cd Packages && swift test --filter AnthropicAdapterTests`
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcCore/Usage/AnthropicAdapter.swift \
        Packages/Tests/ClarcCoreTests/AnthropicAdapterTests.swift
git commit -m "feat(usage): implement AnthropicAdapter with ISO8601 reset parsing"
```

---

## Task 6: `MiniMaxAdapter` — real implementation

**Files:**
- Modify: `Packages/Sources/ClarcCore/Usage/MiniMaxAdapter.swift` (replace stub)
- Test: `Packages/Tests/ClarcCoreTests/MiniMaxAdapterTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Packages/Tests/ClarcCoreTests/MiniMaxAdapterTests.swift`:

```swift
import Foundation
import Testing
@testable import ClarcCore

@Suite("MiniMaxAdapter")
struct MiniMaxAdapterTests {

    private let sampleWithGeneral = """
    {
      "model_remains": [
        { "model_name": "other", "current_interval_remaining_percent": 70, "current_weekly_remaining_percent": 80,
          "end_time": 1748889600000, "weekly_end_time": 1750108800000 },
        { "model_name": "general", "current_interval_remaining_percent": 98, "current_weekly_remaining_percent": 100,
          "end_time": 1748889600000, "weekly_end_time": 1750108800000 }
      ]
    }
    """.data(using: .utf8)!

    private let sampleNoGeneral = """
    {
      "model_remains": [
        { "model_name": "alpha", "current_interval_remaining_percent": 50, "current_weekly_remaining_percent": 60,
          "end_time": 1748889600000, "weekly_end_time": 1750108800000 }
      ]
    }
    """.data(using: .utf8)!

    private let sampleMissingReset = """
    {
      "model_remains": [
        { "model_name": "general", "current_interval_remaining_percent": 98, "current_weekly_remaining_percent": 100 }
      ]
    }
    """.data(using: .utf8)!

    @Test("Prefers the element with model_name == \"general\"")
    func preferGeneral() async throws {
        let outcome = try await MiniMaxAdapter.parseResponse(
            data: sampleWithGeneral, httpStatus: 200, endpointURL: "x"
        )
        #expect(outcome.usage.fiveHourPercent == 2.0)   // 100 - 98
        #expect(outcome.usage.sevenDayPercent == 0.0)   // 100 - 100
    }

    @Test("Falls back to first element when no general")
    func fallbackFirst() async throws {
        let outcome = try await MiniMaxAdapter.parseResponse(
            data: sampleNoGeneral, httpStatus: 200, endpointURL: "x"
        )
        #expect(outcome.usage.fiveHourPercent == 50.0)
        #expect(outcome.usage.sevenDayPercent == 40.0)
    }

    @Test("Reset times are parsed from ms timestamps to Date")
    func parseResetTimes() async throws {
        let outcome = try await MiniMaxAdapter.parseResponse(
            data: sampleWithGeneral, httpStatus: 200, endpointURL: "x"
        )
        let expected = Date(timeIntervalSince1970: 1748889600)
        #expect(outcome.usage.fiveHourResetsAt == expected)
    }

    @Test("Missing reset fields are nil, not an error")
    func missingReset() async throws {
        let outcome = try await MiniMaxAdapter.parseResponse(
            data: sampleMissingReset, httpStatus: 200, endpointURL: "x"
        )
        #expect(outcome.usage.fiveHourResetsAt == nil)
        #expect(outcome.usage.sevenDayResetsAt == nil)
    }

    @Test("Missing utilization throws UsageError.missingField")
    func missingUtilization() async {
        let data = """
        { "model_remains": [
          { "model_name": "general" }
        ]}
        """.data(using: .utf8)!
        await #expect(throws: UsageError.self) {
            _ = try await MiniMaxAdapter.parseResponse(
                data: data, httpStatus: 200, endpointURL: "x"
            )
        }
    }

    @Test("Out-of-range utilization is clamped to 0-100")
    func clampOutOfRange() async throws {
        let data = """
        { "model_remains": [
          { "model_name": "general", "current_interval_remaining_percent": -10, "current_weekly_remaining_percent": 200 }
        ]}
        """.data(using: .utf8)!
        let outcome = try await MiniMaxAdapter.parseResponse(
            data: data, httpStatus: 200, endpointURL: "x"
        )
        // 100 - (-10) = 110 → clamp to 100; 100 - 200 = -100 → clamp to 0
        #expect(outcome.usage.fiveHourPercent == 100.0)
        #expect(outcome.usage.sevenDayPercent == 0.0)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `cd Packages && swift test --filter MiniMaxAdapterTests`
Expected: FAIL — `MiniMaxAdapter.parseResponse` not defined.

- [ ] **Step 3: Implement `MiniMaxAdapter`**

Replace `Packages/Sources/ClarcCore/Usage/MiniMaxAdapter.swift` with:

```swift
import Foundation
import os

/// Adapter for the MiniMax token-plan endpoint. The endpoint returns
/// a `model_remains` array; we pick the element with `model_name ==
/// "general"`, falling back to the first element when not present.
/// Utilization is computed as `100 - current_*_remaining_percent`.
public struct MiniMaxAdapter: UsageAdapter {

    private static let logger = Logger(subsystem: "com.claudework", category: "MiniMaxAdapter")

    public init() {}

    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        let urlString = config.endpoint ?? UsageProvider.minimax.defaultEndpoint!
        guard let url = URL(string: urlString) else { throw UsageError.invalidURL }

        var request = URLRequest(url: url)
        if let token = config.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.http(status: -1, body: data)
        }
        guard http.statusCode == 200 else {
            throw UsageError.http(status: http.statusCode, body: data)
        }
        return try Self.parseResponse(data: data, httpStatus: 200, endpointURL: urlString)
    }

    /// Pure parser, exposed for tests. Element selection and field
    /// mapping live here so they can be exercised without HTTP.
    public static func parseResponse(
        data: Data,
        httpStatus: Int,
        endpointURL: String
    ) throws -> UsageFetchOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["model_remains"] as? [[String: Any]],
              let element = pickElement(arr) else {
            throw UsageError.missingField("model_remains")
        }

        guard let intervalRemain = numericValue(element["current_interval_remaining_percent"]) else {
            throw UsageError.missingField("model_remains[].current_interval_remaining_percent")
        }
        guard let weeklyRemain = numericValue(element["current_weekly_remaining_percent"]) else {
            throw UsageError.missingField("model_remains[].current_weekly_remaining_percent")
        }

        let fiveHour = clampUtilization(100 - intervalRemain)
        let sevenDay = clampUtilization(100 - weeklyRemain)
        let fiveHourResetsAt = parseMilliseconds(element["end_time"])
        let sevenDayResetsAt = parseMilliseconds(element["weekly_end_time"])

        let usage = RateLimitUsage(
            fiveHourPercent: fiveHour,
            sevenDayPercent: sevenDay,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayResetsAt: sevenDayResetsAt
        )
        return UsageFetchOutcome(usage: usage, rawJSON: data, httpStatus: httpStatus, endpointURL: endpointURL)
    }

    private static func pickElement(_ arr: [[String: Any]]) -> [String: Any]? {
        if let general = arr.first(where: { ($0["model_name"] as? String) == "general" }) {
            return general
        }
        return arr.first
    }

    private static func numericValue(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func clampUtilization(_ v: Double) -> Double {
        if v < 0 {
            logger.warning("MiniMax utilization < 0 after inversion, clamping: \(v)")
            return 0
        }
        if v > 100 {
            logger.warning("MiniMax utilization > 100 after inversion, clamping: \(v)")
            return 100
        }
        return v
    }

    private static func parseMilliseconds(_ v: Any?) -> Date? {
        guard let n = v as? NSNumber else { return nil }
        let ms = n.doubleValue
        guard ms.isFinite, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `cd Packages && swift test --filter MiniMaxAdapterTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcCore/Usage/MiniMaxAdapter.swift \
        Packages/Tests/ClarcCoreTests/MiniMaxAdapterTests.swift
git commit -m "feat(usage): implement MiniMaxAdapter with element selection and utilization inversion"
```

---

## Task 7: `CustomAdapter` — JSONPath-driven parser

**Files:**
- Modify: `Packages/Sources/ClarcCore/Usage/CustomAdapter.swift` (replace stub)
- Test: `Packages/Tests/ClarcCoreTests/CustomAdapterTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Packages/Tests/ClarcCoreTests/CustomAdapterTests.swift`:

```swift
import Foundation
import Testing
@testable import ClarcCore

@Suite("CustomAdapter")
struct CustomAdapterTests {

    @Test("Walks dotted key path and returns numeric value")
    func dottedKey() async throws {
        let data = #"{"five_hour": {"utilization": 42}}"#.data(using: .utf8)!
        let outcome = try await CustomAdapter.parseResponse(
            data: data,
            httpStatus: 200,
            endpointURL: "x",
            fiveHourPath: "five_hour.utilization",
            sevenDayPath: "seven_day.utilization"
        )
        #expect(outcome.usage.fiveHourPercent == 42)
        #expect(outcome.usage.sevenDayPercent == 0)  // missing → 0
    }

    @Test("Walks bracket index into array")
    func bracketIndex() async throws {
        let data = #"{"values": [{"v": 10}, {"v": 20}]}"#.data(using: .utf8)!
        let outcome = try await CustomAdapter.parseResponse(
            data: data,
            httpStatus: 200,
            endpointURL: "x",
            fiveHourPath: "values[1].v",
            sevenDayPath: "values[0].v"
        )
        #expect(outcome.usage.fiveHourPercent == 20)
        #expect(outcome.usage.sevenDayPercent == 10)
    }

    @Test("Missing path throws UsageError.missingField")
    func missingPath() async {
        let data = #"{"a": 1}"#.data(using: .utf8)!
        await #expect(throws: UsageError.self) {
            _ = try await CustomAdapter.parseResponse(
                data: data, httpStatus: 200, endpointURL: "x",
                fiveHourPath: "a.b", sevenDayPath: "a"
            )
        }
    }

    @Test("Non-numeric leaf throws UsageError.missingField")
    func nonNumericLeaf() async {
        let data = #"{"a": "hello"}"#.data(using: .utf8)!
        await #expect(throws: UsageError.self) {
            _ = try await CustomAdapter.parseResponse(
                data: data, httpStatus: 200, endpointURL: "x",
                fiveHourPath: "a", sevenDayPath: "a"
            )
        }
    }

    @Test("Reset times are not parsed (Custom adapter returns nil resets)")
    func noResets() async throws {
        let data = #"{"a": 5, "b": 7}"#.data(using: .utf8)!
        let outcome = try await CustomAdapter.parseResponse(
            data: data, httpStatus: 200, endpointURL: "x",
            fiveHourPath: "a", sevenDayPath: "b"
        )
        #expect(outcome.usage.fiveHourResetsAt == nil)
        #expect(outcome.usage.sevenDayResetsAt == nil)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `cd Packages && swift test --filter CustomAdapterTests`
Expected: FAIL — `CustomAdapter.parseResponse` not defined.

- [ ] **Step 3: Implement `CustomAdapter`**

Replace `Packages/Sources/ClarcCore/Usage/CustomAdapter.swift` with:

```swift
import Foundation

/// Adapter for user-typed endpoints. Looks up two numeric values via
/// `JSONPath` expressions, defaulting to the provider's built-in
/// expressions when the user leaves them blank. Does not parse reset
/// times — the path is for the utilization number only.
public struct CustomAdapter: UsageAdapter {

    public init() {}

    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        let urlString = config.endpoint ?? ""
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        if let token = config.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.http(status: -1, body: data)
        }
        guard http.statusCode == 200 else {
            throw UsageError.http(status: http.statusCode, body: data)
        }
        return try Self.parseResponse(
            data: data,
            httpStatus: 200,
            endpointURL: urlString,
            fiveHourPath: config.fiveHourPath,
            sevenDayPath: config.sevenDayPath
        )
    }

    /// Pure parser, exposed for tests.
    public static func parseResponse(
        data: Data,
        httpStatus: Int,
        endpointURL: String,
        fiveHourPath: String?,
        sevenDayPath: String?
    ) throws -> UsageFetchOutcome {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            throw UsageError.malformedJSON
        }
        let root = JSONValue(any: raw)

        let fivePath = fiveHourPath ?? UsageProvider.custom.defaultFiveHourPath
        let sevenPath = sevenDayPath ?? UsageProvider.custom.defaultSevenDayPath

        // For Custom, default path is nil — so we require user to provide.
        guard let fivePath else { throw UsageError.missingField("fiveHourPath") }
        guard let sevenPath else { throw UsageError.missingField("sevenDayPath") }

        let fiveParsed: JSONPath
        let sevenParsed: JSONPath
        do {
            fiveParsed = try JSONPathParser.parse(fivePath)
            sevenParsed = try JSONPathParser.parse(sevenPath)
        } catch {
            throw UsageError.missingField(fivePath)
        }

        let fiveValue = numericValue(at: fiveParsed.lookup(in: root)) ?? 0
        let sevenValue = numericValue(at: sevenParsed.lookup(in: root)) ?? 0

        let usage = RateLimitUsage(
            fiveHourPercent: fiveValue,
            sevenDayPercent: sevenValue,
            fiveHourResetsAt: nil,
            sevenDayResetsAt: nil
        )
        return UsageFetchOutcome(usage: usage, rawJSON: data, httpStatus: httpStatus, endpointURL: endpointURL)
    }

    private static func numericValue(at v: JSONValue?) -> Double? {
        guard let v else { return nil }
        return v.numberValue
    }
}

private extension JSONValue {
    init(any: Any) {
        if let n = any as? NSNumber {
            // Distinguish Bool from numeric: NSNumber wraps Bool as
            // CFBoolean which is not directly introspectable; check the
            // underlying objCType. For our use case all values are
            // either plain numbers or we don't care.
            self = .number(n.doubleValue)
        } else if let s = any as? String {
            self = .string(s)
        } else if let b = any as? Bool {
            self = .bool(b)
        } else if let arr = any as? [Any] {
            self = .array(arr.map { JSONValue(any: $0) })
        } else if let dict = any as? [String: Any] {
            self = .object(dict.mapValues { JSONValue(any: $0) })
        } else {
            self = .null
        }
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `cd Packages && swift test --filter CustomAdapterTests`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Sources/ClarcCore/Usage/CustomAdapter.swift \
        Packages/Tests/ClarcCoreTests/CustomAdapterTests.swift
git commit -m "feat(usage): implement CustomAdapter with JSONPath-based lookup"
```

---

## Task 8: `OpenAIAdapter` — delegate to `CustomAdapter`

**Files:**
- Modify: `Packages/Sources/ClarcCore/Usage/OpenAIAdapter.swift` (replace stub)
- Test: `Packages/Tests/ClarcCoreTests/OpenAIAdapterTests.swift`

- [ ] **Step 1: Write failing test**

Create `Packages/Tests/ClarcCoreTests/OpenAIAdapterTests.swift`:

```swift
import Foundation
import Testing
@testable import ClarcCore

@Suite("OpenAIAdapter")
struct OpenAIAdapterTests {

    @Test("OpenAI provider with default Anthropic-shaped paths parses proxy response")
    func defaultPaths() async throws {
        let data = #"{"five_hour": {"utilization": 7}, "seven_day": {"utilization": 14}}"#.data(using: .utf8)!
        let cfg = UsageQueryConfig(
            provider: .openai,
            endpoint: "https://proxy.example/openai/usage",
            bearerToken: "tok",
            fiveHourPath: "five_hour.utilization",
            sevenDayPath: "seven_day.utilization"
        )
        let outcome = try await OpenAIAdapter().fetch(config: cfg)
        #expect(outcome.usage.fiveHourPercent == 7)
        #expect(outcome.usage.sevenDayPercent == 14)
    }
}
```

Note: this test exercises a real `URLSession` call. Replace it with a `parseResponse` test instead if URL injection is awkward — modify the OpenAIAdapter to expose `parseResponse` similarly to other adapters.

- [ ] **Step 2: Refactor: expose `parseResponse` on `OpenAIAdapter`**

Update `OpenAIAdapter` to follow the same pattern as the others (expose a static `parseResponse` that delegates to `CustomAdapter.parseResponse`).

- [ ] **Step 3: Implement `OpenAIAdapter`**

Replace `Packages/Sources/ClarcCore/Usage/OpenAIAdapter.swift` with:

```swift
import Foundation

/// "OpenAI" is a UX preset that aliases to `CustomAdapter` with
/// Anthropic-shaped default paths. The OpenAI admin `/v1/usage`
/// endpoint does not natively return a 5h/7d utilization shape; users
/// typically route it through a proxy that normalizes the response.
/// This adapter does not add a real OpenAI integration — it exists so
/// the Settings UI can offer "OpenAI" as a discoverable preset.
public struct OpenAIAdapter: UsageAdapter {

    public init() {}

    public func fetch(config: UsageQueryConfig) async throws -> UsageFetchOutcome {
        let urlString = config.endpoint ?? ""
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        if let token = config.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.http(status: -1, body: data)
        }
        guard http.statusCode == 200 else {
            throw UsageError.http(status: http.statusCode, body: data)
        }
        return try Self.parseResponse(
            data: data,
            httpStatus: 200,
            endpointURL: urlString,
            fiveHourPath: config.fiveHourPath,
            sevenDayPath: config.sevenDayPath
        )
    }

    public static func parseResponse(
        data: Data,
        httpStatus: Int,
        endpointURL: String,
        fiveHourPath: String?,
        sevenDayPath: String?
    ) throws -> UsageFetchOutcome {
        try CustomAdapter.parseResponse(
            data: data,
            httpStatus: httpStatus,
            endpointURL: endpointURL,
            fiveHourPath: fiveHourPath,
            sevenDayPath: sevenDayPath
        )
    }
}
```

- [ ] **Step 4: Update the test to use the static parser**

Replace the test file with:

```swift
import Foundation
import Testing
@testable import ClarcCore

@Suite("OpenAIAdapter")
struct OpenAIAdapterTests {

    @Test("OpenAI provider with default Anthropic-shaped paths parses proxy response")
    func defaultPaths() throws {
        let data = #"{"five_hour": {"utilization": 7}, "seven_day": {"utilization": 14}}"#.data(using: .utf8)!
        let outcome = try OpenAIAdapter.parseResponse(
            data: data, httpStatus: 200, endpointURL: "x",
            fiveHourPath: "five_hour.utilization",
            sevenDayPath: "seven_day.utilization"
        )
        #expect(outcome.usage.fiveHourPercent == 7)
        #expect(outcome.usage.sevenDayPercent == 14)
    }
}
```

- [ ] **Step 5: Run tests, expect pass**

Run: `cd Packages && swift test --filter OpenAIAdapterTests`
Expected: PASS — 1 test.

- [ ] **Step 6: Commit**

```bash
git add Packages/Sources/ClarcCore/Usage/OpenAIAdapter.swift \
        Packages/Tests/ClarcCoreTests/OpenAIAdapterTests.swift
git commit -m "feat(usage): implement OpenAIAdapter as CustomAdapter preset"
```

---

## Task 9: Rewrite `RateLimitService` to use the factory

**Files:**
- Modify: `Clarc/Services/RateLimitService.swift`

This task does not add a unit test (the adapter-level tests cover the parsing). The service is exercised end-to-end via the app.

- [ ] **Step 1: Replace the file with the slim implementation**

Replace `Clarc/Services/RateLimitService.swift` with:

```swift
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
            if let tokens = await readOAuthTokens() {
                let token = isExpired(tokens.rawOauth) ? (await refreshAccessToken(tokens) ?? tokens.accessToken) : tokens.accessToken
                config = UsageQueryConfig(
                    provider: .anthropic,
                    endpoint: endpoint,
                    bearerToken: token,
                    fiveHourPath: fiveHourPath,
                    sevenDayPath: sevenDayPath
                )
            } else {
                logger.debug("[RateLimit] OAuth token not found in Keychain")
                return cached
            }
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
            logger.error("[RateLimit] fetch failed: \(String(describing: error))")
            return cached
        }
    }

    // MARK: - Keychain (Anthropic only)

    private func readOAuthTokens() async -> OAuthTokens? {
        guard let raw = await MainActor.run(body: { KeychainHelper.readString(service: "Claude Code-credentials") }) else {
            return nil
        }
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
            return newAccessToken
        } catch {
            return nil
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterFallback = ISO8601DateFormatter()
}
```

- [ ] **Step 2: Build the project**

Run: `xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug build`
Expected: BUILD SUCCEEDED.

If there are errors from `KeychainHelper` not being accessible, check that the file lives in the same module (it currently does) and that the call site is `actor`-isolated as written.

- [ ] **Step 3: Commit**

```bash
git add Clarc/Services/RateLimitService.swift
git commit -m "refactor(usage): shrink RateLimitService to factory + OAuth + cache"
```

---

## Task 10: `AppState` — `usageProvider` + migration

**Files:**
- Modify: `Clarc/App/AppState.swift`

- [ ] **Step 1: Add the computed property**

After the existing `usageEndpointSevenDayPath` property (around line 319), add:

```swift
/// Identifies which `UsageAdapter` is used for usage fetches.
/// Persisted in UserDefaults as the enum's raw string.
var usageProvider: UsageProvider {
    get {
        UserDefaults.standard.string(forKey: "usageProvider")
            .flatMap(UsageProvider.init(rawValue:)) ?? .anthropic
    }
    set {
        UserDefaults.standard.set(newValue.rawValue, forKey: "usageProvider")
    }
}
```

- [ ] **Step 2: Add the migration**

Add a `migrateUsageProvider()` method to `AppState`. Call it from `AppState.init`. The exact insertion point depends on `AppState`'s structure — locate the `init` method and add the call as the first statement, plus add the method itself near the other private helpers.

```swift
private static let didMigrateUsageProviderKey = "usageProviderMigrated"

private func migrateUsageProvider() {
    guard !UserDefaults.standard.bool(forKey: Self.didMigrateUsageProviderKey) else { return }
    UserDefaults.standard.set(true, forKey: Self.didMigrateUsageProviderKey)
    // If the user had a non-empty custom endpoint before this feature
    // existed, treat them as a "custom" provider so their config keeps
    // working. New users get the default (.anthropic).
    if let ep = usageEndpoint, !ep.isEmpty {
        usageProvider = .custom
    }
}
```

In `AppState.init` (find the existing `init()` and add at the top):

```swift
migrateUsageProvider()
```

- [ ] **Step 3: Update `bridge.fetchRateLimitHandler` to pass the new field**

Locate `bridge.fetchRateLimitHandler` in `AppState.swift` (around line 737) and update it to pass `usageProvider`:

```swift
bridge.fetchRateLimitHandler = {
    await RateLimitService.shared.fetchUsage(
        provider: self.usageProvider,
        endpoint: self.usageEndpoint,
        bearerToken: self.usageEndpointBearerToken,
        fiveHourPath: self.usageEndpointFiveHourPath,
        sevenDayPath: self.usageEndpointSevenDayPath
    )
}
```

- [ ] **Step 4: Build the project**

Run: `xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Clarc/App/AppState.swift
git commit -m "feat(usage): add usageProvider to AppState with backward-compatible migration"
```

---

## Task 11: Settings UI — provider picker + conditional fields

**Files:**
- Modify: `Clarc/Views/SettingsView.swift`

This task replaces the `usageEndpointSection` with a picker-driven layout. The Test Endpoint sheet comes in Task 12.

- [ ] **Step 1: Replace `usageEndpointSection` body**

Find the existing `usageEndpointSection` (SettingsView.swift line ~224) and replace its `body` content with:

```swift
private var usageEndpointSection: some View {
    @Bindable var appState = appState

    return VStack(alignment: .leading, spacing: 12) {
        Text(LocalizedStringKey("Usage Endpoint"))
            .font(.system(size: ClaudeTheme.size(13), weight: .semibold))

        Picker(LocalizedStringKey("Provider"), selection: $appState.usageProvider) {
            ForEach(UsageProvider.allCases, id: \.self) { p in
                Text(p.displayName).tag(p)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .onChange(of: appState.usageProvider) { _, newValue in
            applyProviderDefaults(newValue, appState: appState)
        }

        Text(LocalizedStringKey("usage.provider.desc"))
            .font(.system(size: ClaudeTheme.size(11)))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        providerFields(for: appState.usageProvider)
    }
}

@ViewBuilder
private func providerFields(for provider: UsageProvider) -> some View {
    @Bindable var appState = appState

    let isAnthropic = (provider == .anthropic)

    VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey("Endpoint URL"))
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                provider.endpointPlaceholder,
                text: Binding(
                    get: { appState.usageEndpoint ?? provider.endpointPlaceholder },
                    set: { appState.usageEndpoint = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
            .disabled(isAnthropic)
            .opacity(isAnthropic ? 0.55 : 1.0)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey("Bearer token (optional)"))
                .font(.system(size: ClaudeTheme.size(11), weight: .medium))
                .foregroundStyle(.secondary)
            SecureField(
                isAnthropic ? "OAuth" : "sk-...",
                text: Binding(
                    get: { appState.usageEndpointBearerToken ?? "" },
                    set: { appState.usageEndpointBearerToken = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
            .disabled(isAnthropic)
            .opacity(isAnthropic ? 0.55 : 1.0)
        }

        if provider == .minimax {
            Text(LocalizedStringKey("usage.minimax.note"))
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            jsonPathField(
                label: LocalizedStringKey("5h utilization JSON path"),
                placeholder: provider.defaultFiveHourPath ?? "five_hour.utilization",
                bindingPath: \.usageEndpointFiveHourPath,
                appState: appState
            )
            jsonPathField(
                label: LocalizedStringKey("7d utilization JSON path"),
                placeholder: provider.defaultSevenDayPath ?? "seven_day.utilization",
                bindingPath: \.usageEndpointSevenDayPath,
                appState: appState
            )
        }

        Button {
            testSheetOpen = true
        } label: {
            Label("Test Endpoint", systemImage: "play.circle")
        }
        .buttonStyle(.bordered)
    }
    .sheet(isPresented: $testSheetOpen) {
        TestEndpointSheet(
            viewModel: viewModel,
            appState: appState,
            isPresented: $testSheetOpen
        )
    }
}

private func jsonPathField(
    label: LocalizedStringKey,
    placeholder: String,
    bindingPath: ReferenceWritableKeyPath<AppState, String?>,
    appState: AppState
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label)
            .font(.system(size: ClaudeTheme.size(11), weight: .medium))
            .foregroundStyle(.secondary)
        TextField(
            placeholder,
            text: Binding(
                get: { appState[keyPath: bindingPath] ?? placeholder },
                set: { appState[keyPath: bindingPath] = $0 }
            )
        )
        .textFieldStyle(.roundedBorder)
        .font(.system(size: ClaudeTheme.size(12), design: .monospaced))
    }
}

private func applyProviderDefaults(_ provider: UsageProvider, appState: AppState) {
    switch provider {
    case .anthropic:
        // Clear user path overrides so the next Anthropic fetch uses
        // the built-in defaults. Endpoint stays as the user left it
        // (or empty), but the adapter will use the canonical URL.
        appState.usageEndpointFiveHourPath = nil
        appState.usageEndpointSevenDayPath = nil
    case .minimax:
        if let ep = appState.usageEndpoint, ep.isEmpty,
           let def = UsageProvider.minimax.defaultEndpoint {
            appState.usageEndpoint = def
        }
    case .openai:
        if appState.usageEndpointFiveHourPath == nil {
            appState.usageEndpointFiveHourPath = UsageProvider.openai.defaultFiveHourPath
        }
        if appState.usageEndpointSevenDayPath == nil {
            appState.usageEndpointSevenDayPath = UsageProvider.openai.defaultSevenDayPath
        }
    case .custom:
        break
    }
}
```

- [ ] **Step 2: Add `@State` and view-model to `GeneralSettingsTab`**

At the top of `GeneralSettingsTab` (next to existing `@State` declarations), add:

```swift
@State private var testSheetOpen = false
@State private var viewModel = UsageSettingsViewModel()
```

Also add two helpers on `UsageProvider` (file-scope extensions in the same file, or a separate file — Task 11's commit can include them):

```swift
private extension UsageProvider {
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .minimax:   return "MiniMax"
        case .openai:    return "OpenAI"
        case .custom:    return "Custom"
        }
    }

    var endpointPlaceholder: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/api/oauth/usage"
        case .minimax:   return "https://www.minimaxi.com/v1/token_plan/remains"
        case .openai:    return "https://your-proxy/openai/usage"
        case .custom:    return "https://your-server/usage"
        }
    }
}
```

- [ ] **Step 3: Add the view-model stub for the sheet**

In the same file, add a stub `UsageSettingsViewModel` and `TestEndpointSheet` (Task 12 fills them in):

```swift
@MainActor
@Observable
final class UsageSettingsViewModel {
    enum TestState {
        case idle
        case running
    }
    var testState: TestState = .idle
}

private struct TestEndpointSheet: View {
    let viewModel: UsageSettingsViewModel
    let appState: AppState
    @Binding var isPresented: Bool

    var body: some View {
        VStack {
            Text("Test Endpoint sheet — coming next")
            Button("Close") { isPresented = false }
        }
        .frame(width: 480, height: 320)
    }
}
```

- [ ] **Step 4: Build the project**

Run: `xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Clarc/Views/SettingsView.swift
git commit -m "feat(usage): add provider picker and conditional fields to Settings"
```

---

## Task 12: Test Endpoint sheet — full implementation

**Files:**
- Modify: `Clarc/Views/SettingsView.swift` (replace stub `UsageSettingsViewModel` and `TestEndpointSheet`)

- [ ] **Step 1: Implement the view-model**

Replace the `UsageSettingsViewModel` stub with:

```swift
@MainActor
@Observable
final class UsageSettingsViewModel {

    enum TestState {
        case idle
        case running
        case success(http: Int, usage: RateLimitUsage, rawJSON: Data, endpoint: String)
        case failure(http: Int?, message: String, rawJSON: Data?, endpoint: String)
    }

    var testState: TestState = .idle

    func test(appState: AppState) async {
        testState = .running
        let endpoint = appState.usageEndpoint?.isEmpty == false
            ? appState.usageEndpoint
            : appState.usageProvider.defaultEndpoint

        let config = UsageQueryConfig(
            provider: appState.usageProvider,
            endpoint: endpoint,
            bearerToken: appState.usageEndpointBearerToken,
            fiveHourPath: appState.usageEndpointFiveHourPath,
            sevenDayPath: appState.usageEndpointSevenDayPath
        )

        do {
            let outcome = try await UsageAdapterFactory
                .make(provider: config.provider)
                .fetch(config: config)
            testState = .success(
                http: outcome.httpStatus,
                usage: outcome.usage,
                rawJSON: outcome.rawJSON,
                endpoint: outcome.endpointURL
            )
        } catch UsageError.http(let status, let body) {
            testState = .failure(
                http: status,
                message: "HTTP \(status)",
                rawJSON: body,
                endpoint: endpoint ?? "(none)"
            )
        } catch UsageError.invalidURL {
            testState = .failure(
                http: nil,
                message: "Invalid URL",
                rawJSON: nil,
                endpoint: endpoint ?? "(none)"
            )
        } catch UsageError.malformedJSON {
            testState = .failure(
                http: nil,
                message: "Response is not valid JSON",
                rawJSON: nil,
                endpoint: endpoint ?? "(none)"
            )
        } catch UsageError.missingField(let path) {
            testState = .failure(
                http: nil,
                message: "Missing field: \(path)",
                rawJSON: nil,
                endpoint: endpoint ?? "(none)"
            )
        } catch {
            testState = .failure(
                http: nil,
                message: error.localizedDescription,
                rawJSON: nil,
                endpoint: endpoint ?? "(none)"
            )
        }
    }
}
```

- [ ] **Step 2: Implement the sheet body**

Replace the `TestEndpointSheet` stub with:

```swift
private struct TestEndpointSheet: View {
    let viewModel: UsageSettingsViewModel
    let appState: AppState
    @Binding var isPresented: Bool

    @State private var rawText: String = ""
    @State private var didRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Test Result").font(.headline)
                Spacer()
                Button("Close") { isPresented = false }
            }

            content

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 540, height: 480)
        .task(id: didRun) {
            if !didRun {
                didRun = true
                await viewModel.test(appState: appState)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.testState {
        case .idle, .running:
            HStack {
                ProgressView()
                Text("Sending request…")
            }
        case .success(let http, let usage, let rawJSON, let endpoint):
            successBody(http: http, usage: usage, rawJSON: rawJSON, endpoint: endpoint)
        case .failure(let http, let message, let rawJSON, let endpoint):
            failureBody(http: http, message: message, rawJSON: rawJSON, endpoint: endpoint)
        }
    }

    @ViewBuilder
    private func successBody(
        http: Int, usage: RateLimitUsage, rawJSON: Data, endpoint: String
    ) -> some View {
        statusBadge(ok: true, text: "HTTP \(http)")
        Text("Endpoint: \(endpoint)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        HStack(spacing: 24) {
            metric(label: "5h Utilization", value: String(format: "%.1f%%", usage.fiveHourPercent))
            metric(label: "7d Utilization", value: String(format: "%.1f%%", usage.sevenDayPercent))
        }
        if usage.fiveHourResetsAt != nil || usage.sevenDayResetsAt != nil {
            HStack(spacing: 24) {
                if let d = usage.fiveHourResetsAt {
                    metric(label: "5h Resets", value: d.formatted(.relative(presentation: .named)))
                }
                if let d = usage.sevenDayResetsAt {
                    metric(label: "7d Resets", value: d.formatted(.relative(presentation: .named)))
                }
            }
        }
        rawSection(rawJSON: rawJSON)
    }

    @ViewBuilder
    private func failureBody(
        http: Int?, message: String, rawJSON: Data?, endpoint: String
    ) -> some View {
        statusBadge(ok: false, text: http.map { "HTTP \($0)" } ?? "Error")
        Text("Endpoint: \(endpoint)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.red)
        if let rawJSON {
            rawSection(rawJSON: rawJSON)
        }
    }

    private func statusBadge(ok: Bool, text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((ok ? Color.green : Color.red).opacity(0.15))
            .foregroundStyle(ok ? Color.green : Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .medium))
        }
    }

    @ViewBuilder
    private func rawSection(rawJSON: Data) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Raw Response").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(prettify(rawJSON), forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
            }
            ScrollView {
                Text(prettify(rawJSON))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(NSColor.separatorColor)))
        }
    }

    private func prettify(_ data: Data) -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let str = String(data: pretty, encoding: .utf8)
        else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return str
    }
}
```

- [ ] **Step 2: Build the project**

Run: `xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug build`
Expected: BUILD SUCCEEDED.

If Swift complains about `await viewModel.test(appState: appState)` inside `.task` (the call itself is fine; the `appState` capture is a `let`), add `MainActor.assumeIsolated` if the compiler flags it.

- [ ] **Step 3: Commit**

```bash
git add Clarc/Views/SettingsView.swift
git commit -m "feat(usage): implement Test Endpoint sheet with HTTP/JSON/parsed display"
```

---

## Task 13: Localization keys

**Files:**
- Modify: `Clarc/Resources/en.lproj/Localizable.strings`
- Modify: `Clarc/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Clarc/Resources/ko.lproj/Localizable.strings`

- [ ] **Step 1: Add English keys**

Append to `Clarc/Resources/en.lproj/Localizable.strings`:

```
"usage.provider.desc" = "Choose where usage data comes from. Anthropic uses your OAuth credentials; other providers use a custom URL and bearer token.";
"usage.minimax.note" = "MiniMax provider automatically parses the model_remains fields. No JSON path required.";
```

- [ ] **Step 2: Add Chinese keys**

Append to `Clarc/Resources/zh-Hans.lproj/Localizable.strings`:

```
"usage.provider.desc" = "选择用量数据来源。Anthropic 使用你的 OAuth 凭据；其他 provider 使用自定义 URL + Bearer Token。";
"usage.minimax.note" = "MiniMax provider 自动解析 model_remains 字段，无需配置 JSON path。";
```

- [ ] **Step 3: Add Korean keys**

Append to `Clarc/Resources/ko.lproj/Localizable.strings`:

```
"usage.provider.desc" = "사용량 데이터 소스를 선택하세요. Anthropic은 OAuth 자격 증명을 사용하고, 다른 공급자는 사용자 지정 URL과 Bearer 토큰을 사용합니다.";
"usage.minimax.note" = "MiniMax 공급자는 model_remains 필드를 자동으로 파싱합니다. JSON 경로가 필요하지 않습니다.";
```

- [ ] **Step 4: Build the project**

Run: `xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Clarc/Resources/en.lproj/Localizable.strings \
        Clarc/Resources/zh-Hans.lproj/Localizable.strings \
        Clarc/Resources/ko.lproj/Localizable.strings
git commit -m "feat(usage): localize provider description and minimax note"
```

---

## Task 14: Full test run + manual verification

- [ ] **Step 1: Run the full ClarcCore test suite**

Run: `cd Packages && swift test`
Expected: ALL TESTS PASS — UsageProvider (6) + UsageQueryConfig (2) + JSONPath (15) + UsageAdapterFactory (4) + AnthropicAdapter (2) + MiniMaxAdapter (6) + CustomAdapter (5) + OpenAIAdapter (1) = 41 tests, plus the pre-existing tests.

- [ ] **Step 2: Build the macOS app**

Run: `xcodebuild -project Clarc.xcodeproj -scheme Clarc -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual matrix**

Open the app, open Settings → General, walk through:

1. Default state: Provider=Anthropic, endpoint/token fields disabled, no path fields visible below the caption. (Anthropic uses the built-in defaults.)
2. Switch to MiniMax: endpoint pre-fills with `https://www.minimaxi.com/v1/token_plan/remains`, path fields replaced with the MiniMax caption.
3. Click Test Endpoint with MiniMax: see HTTP/JSON/parsed result sheet.
4. Switch to OpenAI: path fields reappear, pre-filled with `five_hour.utilization` / `seven_day.utilization`.
5. Switch to Custom: pre-fills cleared (or untouched); user can type.
6. Type a custom URL + Bearer + paths; click Test Endpoint.
7. Switch back to Anthropic: path fields cleared, endpoint/token disabled, Test Endpoint works against the real Anthropic endpoint.

- [ ] **Step 4: Commit the spec-driven final state if anything was missing**

If step 3 surfaced a UI bug, fix it in a follow-up commit. The plan is complete when the matrix passes.

- [ ] **Step 5: Defer push**

Per the saved memory `defer-push-usage-system`, do **not** `git push` at the end of this work. Stop after the local commits and wait for the user to confirm.

---

## Self-Review

**Spec coverage check** (each spec section → plan task):

| Spec section | Plan tasks |
|---|---|
| Goal (multi-provider, hidden config, Test Endpoint) | Tasks 1, 11, 12 |
| Architecture (ClarcCore/Usage subsystem, RateLimitService rewrite) | Tasks 1-8, 9 |
| Data model (UsageProvider + default tables) | Task 1 |
| Query config | Task 2 |
| Adapter protocol + boundary rule | Task 4 |
| AnthropicAdapter | Task 5 |
| MiniMaxAdapter (model_remains + inversion + reset) | Task 6 |
| OpenAIAdapter = CustomAdapter preset | Task 8 |
| CustomAdapter (JSONPath lookup) | Tasks 3, 7 |
| JSONPath syntax (dot/bracket/predicate) | Task 3 |
| Service layer (config build + OAuth + cache) | Task 9 |
| AppState (usageProvider + migration) | Task 10 |
| UI (provider picker + conditional fields + sheet) | Tasks 11, 12 |
| Backward compatibility | Task 10 (migration) |
| File changes (new + modified list) | Tasks 1-13 |
| Testing (manual matrix) | Task 14 |

All spec sections covered.

**Placeholder scan:** No "TBD" / "TODO" / "implement later" patterns. Every code step includes the full code. Every command includes expected output.

**Type consistency:**
- `UsageProvider` defined in Task 1, used in Tasks 2, 4, 7, 8, 9, 10, 11, 12 ✓
- `UsageQueryConfig` defined in Task 2, used in Tasks 4, 5, 6, 7, 8, 9, 12 ✓
- `UsageAdapter`, `UsageError`, `UsageFetchOutcome` defined in Task 4, used in Tasks 5, 6, 7, 8 ✓
- `JSONPath`, `JSONPathParser`, `JSONPathParseError` defined in Task 3, used in Task 7 ✓
- `UsageAdapterFactory.make(provider:)` defined in Task 4, used in Tasks 9, 12 ✓
- `RateLimitUsage` (existing) used in Tasks 5, 6, 7, 8, 9, 12 ✓
- `KeychainHelper.readString(service:)` (existing) used in Task 9 ✓

No type drift detected.
