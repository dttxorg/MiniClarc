import Foundation

/// A parsed JSON path expression. The tree stores the leaf segment first:
/// `a.b[0]` is represented as `.index(0, .key("b", .key("a", .root)))`.
/// Lookup resolves `rest` from the root value first, then applies the
/// current key/index/predicate segment to that intermediate value.
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
        let chars = Array(source)
        var position = 0
        var path: JSONPath = .root

        while position < chars.count {
            if chars[position] == "." {
                position += 1
                guard position < chars.count else {
                    throw JSONPathParseError.unexpectedCharacter(".", position - 1)
                }
            }

            let current = chars[position]
            if current == "[" {
                path = try parseBracketSegment(into: path, chars: chars, position: &position)
            } else if current.isNumber {
                let index = try parseDigits(chars: chars, position: &position)
                path = .index(index, path)
            } else if current.isLetter || current == "_" {
                let name = try parseIdentifier(chars: chars, position: &position)
                path = .key(name, path)
            } else {
                throw JSONPathParseError.unexpectedCharacter(current, position)
            }

            if position < chars.count,
               chars[position] != ".",
               chars[position] != "[" {
                throw JSONPathParseError.trailingContent(position)
            }
        }

        return path
    }

    // MARK: - Bracket segment: [n] or [@k=v]

    private static func parseBracketSegment(
        into path: JSONPath,
        chars: [Character],
        position: inout Int
    ) throws -> JSONPath {
        position += 1
        guard position < chars.count else {
            throw JSONPathParseError.unclosedBracket(position)
        }
        let first = chars[position]
        if first == "@" {
            position += 1
            guard position < chars.count else {
                throw JSONPathParseError.emptyPredicate(position)
            }
            let key = try parseIdentifier(chars: chars, position: &position)
            guard position < chars.count else {
                throw JSONPathParseError.missingEqualsInPredicate(position)
            }
            guard chars[position] == "=" else {
                throw JSONPathParseError.missingEqualsInPredicate(position)
            }
            position += 1
            guard position < chars.count else {
                throw JSONPathParseError.emptyPredicate(position)
            }
            let value = try parseStringValue(chars: chars, position: &position)
            guard position < chars.count, chars[position] == "]" else {
                throw JSONPathParseError.unclosedBracket(position)
            }
            position += 1
            return .predicate(key, value, path)
        } else if first.isNumber {
            let index = try parseDigits(chars: chars, position: &position)
            guard position < chars.count else {
                throw JSONPathParseError.unclosedBracket(position)
            }
            guard chars[position] == "]" else {
                throw JSONPathParseError.unexpectedCharacter(chars[position], position)
            }
            position += 1
            return .index(index, path)
        } else {
            throw JSONPathParseError.unexpectedCharacter(first, position)
        }
    }

    // MARK: - Primitive parsers

    private static func parseIdentifier(
        chars: [Character],
        position: inout Int
    ) throws -> String {
        guard position < chars.count else {
            throw JSONPathParseError.unexpectedCharacter("\0", position)
        }
        let first = chars[position]
        guard first.isLetter || first == "_" else {
            throw JSONPathParseError.unexpectedCharacter(first, position)
        }
        let start = position
        position += 1
        while position < chars.count {
            let ch = chars[position]
            guard ch.isLetter || ch.isNumber || ch == "_" else { break }
            position += 1
        }
        return String(chars[start..<position])
    }

    private static func parseDigits(
        chars: [Character],
        position: inout Int
    ) throws -> Int {
        guard position < chars.count, chars[position].isNumber else {
            let ch = position < chars.count ? chars[position] : "\0"
            throw JSONPathParseError.unexpectedCharacter(ch, position)
        }
        let start = position
        position += 1
        while position < chars.count, chars[position].isNumber {
            position += 1
        }
        let digits = String(chars[start..<position])
        guard let value = Int(digits) else {
            throw JSONPathParseError.unexpectedCharacter(chars[start], start)
        }
        return value
    }

    private static func parseStringValue(
        chars: [Character],
        position: inout Int
    ) throws -> String {
        let start = position
        while position < chars.count, chars[position] != "]" {
            position += 1
        }
        guard position > start else {
            throw JSONPathParseError.emptyPredicate(position)
        }
        return String(chars[start..<position])
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
            guard let base = rest.lookup(in: root) else { return nil }
            return base[name]
        case .index(let n, let rest):
            guard let base = rest.lookup(in: root) else { return nil }
            return base[n]
        case .predicate(let key, let value, let rest):
            guard let base = rest.lookup(in: root),
                  case .array(let arr) = base,
                  let match = arr.first(where: { element in
                      if case .string(let s)? = element[key] {
                          return s == value
                      }
                      return false
                  })
            else { return nil }
            return match
        }
    }
}
