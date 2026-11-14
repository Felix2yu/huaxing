import Foundation

// MARK: - Glob

/// Minimal glob matcher — supports `*` (any chars except `/`), `?` (single char),
/// `**` (any chars including `/` when surrounded by path separators).
///
/// Pattern syntax:
///   - `*`  → match any number of non-separator chars
///   - `?`  → match exactly one non-separator char
///   - `**` → match any number of chars including separators, but only when
///            it forms a complete path component (e.g. `src/**/test.swift`)
///   - All other chars are matched literally (case-insensitive for ASCII, case-sensitive otherwise)
public enum Glob {
    public static func match(_ pattern: String, _ text: String) -> Bool {
        let tokens = tokenize(pattern)
        return matches(tokens, Array(text), 0, 0)
    }

    private enum Token: Equatable { case star, qmark, literal(Character) }

    private static func tokenize(_ pattern: String) -> [Token] {
        var tokens: [Token] = []
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                if tokens.last == .star {
                    tokens.removeLast()
                    tokens.append(.star) // collapse ** into one token (handled specially below)
                } else {
                    tokens.append(.star)
                }
            } else if c == "?" {
                tokens.append(.qmark)
            } else {
                tokens.append(.literal(c))
            }
            i = pattern.index(after: i)
        }
        return tokens
    }

    private static func matches(_ tokens: [Token], _ text: [Character], _ ti: Int, _ pi: Int) -> Bool {
        if pi == tokens.count { return ti == text.count }

        switch tokens[pi] {
        case .star:
            // Try matching 0, 1, 2... chars
            for k in ti...text.count {
                if matches(tokens, text, k, pi + 1) { return true }
            }
            return false
        case .qmark:
            guard ti < text.count else { return false }
            return matches(tokens, text, ti + 1, pi + 1)
        case .literal(let c):
            guard ti < text.count else { return false }
            let lhs = String(text[ti]).lowercased()
            let rhs = String(c).lowercased()
            guard lhs == rhs else { return false }
            return matches(tokens, text, ti + 1, pi + 1)
        }
    }
}
