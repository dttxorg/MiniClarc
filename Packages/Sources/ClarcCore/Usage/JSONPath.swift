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
        var position = 0
        let path = try parseComponent(iterator: &iter, position: &position)
        if iter.next() != nil {
            throw JSONPathParseError.trailingContent(position)
        }
        return path
    }

    // MARK: - Component parser

    private static func parseComponent(
        iterator: inout String.Iterator,
        position: inout Int
    ) throws -> JSONPath {
        var path: JSONPath = .root
        var current: Character? = iterator.next()
        if current != nil { position += 1 }

        while let c = current {
            switch c {
            case ".":
                // Consume '.', then read identifier or digit.
                guard let after = iterator.next() else {
                    throw JSONPathParseError.unexpectedCharacter(".", position)
                }
                position += 1
                if after == "[" {
                    path = try parseBracketSegment(into: path, iterator: &iterator, position: &position)
                    current = iterator.next()
                    if current != nil { position += 1 }
                } else if after.isNumber {
                    // .0.b — number is the index, then continue
                    let (idx, consumed) = try parseDigits(first: after, iterator: &iterator, position: &position)
                    path = .index(idx, path)
                    current = consumed
                } else if after.isLetter || after == "_" {
                    let (name, afterChar) = try parseIdentifier(first: after, iterator: &iterator, position: &position)
                    path = .key(name, path)
                    current = afterChar
                } else {
                    throw JSONPathParseError.unexpectedCharacter(after, position - 1)
                }

            case "[":
                path = try parseBracketSegment(into: path, iterator: &iterator, position: &position)
                current = iterator.next()
                if current != nil { position += 1 }

            case "]":
                // Caller (parseBracketSegment) handles closing bracket
                // by passing us a new next. This case shouldn't fire at
                // the top level.
                return path

            default:
                if c.isLetter || c == "_" {
                    let (name, after) = try parseIdentifier(first: c, iterator: &iterator, position: &position)
                    path = .key(name, path)
                    current = after
                } else {
                    throw JSONPathParseError.unexpectedCharacter(c, position - 1)
                }
            }
        }
        return path
    }

    // MARK: - Bracket segment: [n] or [@k=v]

    private static func parseBracketSegment(
        into path: JSONPath,
        iterator: inout String.Iterator,
        position: inout Int
    ) throws -> JSONPath {
        guard let first = iterator.next() else {
            throw JSONPathParseError.unclosedBracket(position)
        }
        position += 1
        if first == "@" {
            // predicate: @k=v
            guard let k1 = iterator.next() else {
                throw JSONPathParseError.emptyPredicate(position)
            }
            position += 1
            let (key, afterKey) = try parseIdentifier(first: k1, iterator: &iterator, position: &position)
            guard let eq = iterator.next() else {
                throw JSONPathParseError.missingEqualsInPredicate(position)
            }
            position += 1
            guard eq == "=" else {
                throw JSONPathParseError.missingEqualsInPredicate(position - 1)
            }
            guard let v1 = iterator.next() else {
                throw JSONPathParseError.emptyPredicate(position)
            }
            position += 1
            let (value, afterValue) = try parseStringValue(first: v1, iterator: &iterator, position: &position)
            guard let close = iterator.next() else {
                throw JSONPathParseError.unclosedBracket(position)
            }
            position += 1
            guard close == "]" else {
                throw JSONPathParseError.unexpectedCharacter(close, position - 1)
            }
            return .predicate(key, value, path)
        } else if first.isNumber {
            let (idx, after) = try parseDigits(first: first, iterator: &iterator, position: &position)
            guard let close = iterator.next() else {
                throw JSONPathParseError.unclosedBracket(position)
            }
            position += 1
            guard close == "]" else {
                throw JSONPathParseError.unexpectedCharacter(close, position - 1)
            }
            return .index(idx, path)
        } else {
            throw JSONPathParseError.unexpectedCharacter(first, position - 1)
        }
    }

    // MARK: - Primitive parsers

    private static func parseIdentifier(
        first: Character,
        iterator: inout String.Iterator,
        position: inout Int
    ) throws -> (String, Character?) {
        var name = String(first)
        var c: Character? = iterator.next()
        if c != nil { position += 1 }
        while let ch = c, ch.isLetter || ch.isNumber || ch == "_" {
            name.append(ch)
            c = iterator.next()
            if c != nil { position += 1 }
        }
        return (name, c)
    }

    private static func parseDigits(
        first: Character,
        iterator: inout String.Iterator,
        position: inout Int
    ) throws -> (Int, Character?) {
        var digits = String(first)
        var c: Character? = iterator.next()
        if c != nil { position += 1 }
        while let ch = c, ch.isNumber {
            digits.append(ch)
            c = iterator.next()
            if c != nil { position += 1 }
        }
        guard let value = Int(digits) else {
            throw JSONPathParseError.unexpectedCharacter(first, position - digits.count)
        }
        return (value, c)
    }

    private static func parseStringValue(
        first: Character,
        iterator: inout String.Iterator,
        position: inout Int
    ) throws -> (String, Character?) {
        // Bare value: read until we hit ']'
        var s = String(first)
        var c: Character? = iterator.next()
        if c != nil { position += 1 }
        while let ch = c, ch != "]" {
            s.append(ch)
            c = iterator.next()
            if c != nil { position += 1 }
        }
        return (s, c)
    }
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
            guard let next = root[name] else { return nil }
            return rest.lookup(in: next)
        case .index(let n, let rest):
            guard let next = root[n] else { return nil }
            return rest.lookup(in: next)
        case .predicate(let key, let value, let rest):
            guard case .array(let arr) = root,
                  let match = arr.first(where: { element in
                      if case .string(let s)? = element[key] {
                          return s == value
                      }
                      return false
                  })
            else { return nil }
            return rest.lookup(in: match)
        }
    }
}
