import Foundation

// MARK: - CommandSpec

/// Describes a command's positional params + flags so `usage()` can self-generate.
public struct Flag: Sendable {
    public let name: String                 // long name: "preset"
    public let short: String?               // short flag: "p" (single char)
    public let description: String
    public let requiresValue: Bool

    public init(name: String, short: String? = nil, description: String, requiresValue: Bool = false) {
        self.name = name; self.short = short
        self.description = description; self.requiresValue = requiresValue
    }
}

public struct Positional: Sendable {
    public let name: String
    public let description: String
    public let required: Bool

    public init(name: String, description: String, required: Bool = true) {
        self.name = name; self.description = description; self.required = required
    }
}

public struct CommandSpec: Sendable {
    public let name: String
    public let description: String
    public let positionals: [Positional]
    public let flags: [Flag]

    public init(name: String, description: String, positionals: [Positional] = [], flags: [Flag] = []) {
        self.name = name; self.description = description
        self.positionals = positionals; self.flags = flags
    }

    public func usage() -> String {
        var s = "huaxingctl \(name)"
        for p in positionals {
            s += p.required ? " <\(p.name)>" : " [\(p.name)]"
        }
        for f in flags where f.requiresValue {
            s += f.short.map { " [-\($0) <\(f.name)]" } ?? " [--\(f.name) <val>]"
        }
        for f in flags where !f.requiresValue {
            s += f.short.map { " [-\($0)]" } ?? " [--\(f.name)]"
        }
        s += "\n  \(description)\n"
        if !flags.isEmpty {
            s += "\n  Flags:\n"
            for f in flags {
                let short = f.short.map { "-\($0)" } ?? "  "
                s += "    --\(f.name)\t\(short)\t\(f.description)\n"
            }
        }
        return s
    }
}

// MARK: - ArgParser

/// Zero-dependency positional + flag parser. Supports:
///   - `--k value` / `--k=value`
///   - Short flag merging: `-abc` means `-a -b -c` (for non-value flags)
///   - `--` stops flag parsing, remainder are all positionals
public struct ArgParser: Sendable {
    public struct Parsed: Sendable {
        public var positionals: [String] = []
        public var flags: [String: String] = [:]   // value flags store string; bool flags store ""
        public var boolFlags: Set<String> = []

        public func has(_ long: String) -> Bool {
            boolFlags.contains(long) || flags[long] != nil
        }

        public func value(_ long: String) -> String? { flags[long] }

        public func requireValue(_ long: String) throws -> String {
            guard let v = flags[long] else { throw ArgError.missingValue("--\(long)") }
            return v
        }
    }

    public enum ArgError: Error, Sendable, CustomStringConvertible {
        case unknownFlag(String)
        case missingValue(String)
        case missingPositional(String)

        public var description: String {
            switch self {
            case .unknownFlag(let f): return "Unknown flag: \(f)"
            case .missingValue(let f): return "\(f) requires a value"
            case .missingPositional(let p): return "Missing required positional: \(p)"
            }
        }
    }

    public static func parse(_ args: [String], spec: CommandSpec) throws -> Parsed {
        var result = Parsed()
        var flagIndex: [String: Flag] = [:]
        var shortIndex: [String: Flag] = [:]
        for f in spec.flags {
            flagIndex[f.name] = f
            if let s = f.short { shortIndex[s] = f }
        }

        var i = 0
        var raw = args
        if let first = raw.first, first == spec.name { raw.removeFirst() }

        while i < raw.count {
            let tok = raw[i]
            if tok == "--" {
                // Remainder are positionals
                result.positionals.append(contentsOf: raw.dropFirst(i + 1))
                break
            }

            if tok.hasPrefix("--") {
                let bare = String(tok.dropFirst(2))
                // --k=value
                if let eq = bare.firstIndex(of: "=") {
                    let k = String(bare[..<eq])
                    let v = String(bare[bare.index(after: eq)...])
                    guard let f = flagIndex[k] else { throw ArgError.unknownFlag("--\(bare)") }
                    if f.requiresValue { result.flags[k] = v }
                    else { result.boolFlags.insert(k) }
                    i += 1
                    continue
                }
                // --k value  OR  --k (bool)
                guard let f = flagIndex[bare] else { throw ArgError.unknownFlag("--\(bare)") }
                if f.requiresValue {
                    let v = raw.dropFirst(i + 1).first
                    guard let v, !v.hasPrefix("-") else { throw ArgError.missingValue("--\(bare)") }
                    result.flags[bare] = v
                    i += 2
                } else {
                    result.boolFlags.insert(bare)
                    i += 1
                }
                continue
            }

            if tok.hasPrefix("-") && tok.count >= 2 {
                let tail = String(tok.dropFirst())
                // Try short flag merging. `advance` is how many argv tokens this
                // group consumes (2 when the value is the next token).
                let chars = Array(tail)
                var idx = 0
                var advance = 1
                while idx < chars.count {
                    let ch = String(chars[idx])
                    guard let f = shortIndex[ch] else { throw ArgError.unknownFlag("-\(ch)") }
                    if f.requiresValue {
                        // Value flag — rest of merged string is the value, or next token
                        let rest = idx + 1 < chars.count ? String(chars.dropFirst(idx + 1)) : nil
                        if let rest, !rest.isEmpty {
                            result.flags[f.name] = rest
                        } else {
                            guard i + 1 < raw.count else { throw ArgError.missingValue("-\(ch)") }
                            result.flags[f.name] = raw[i + 1]
                            advance = 2
                        }
                        break
                    } else {
                        result.boolFlags.insert(f.name)
                        idx += 1
                    }
                }
                i += advance
                continue
            }

            // Positional
            result.positionals.append(tok)
            i += 1
        }

        return result
    }
}
