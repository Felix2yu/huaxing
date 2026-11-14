import Foundation

// MARK: - CollisionPolicy

public enum CollisionPolicy: Sendable, Codable, Equatable, CaseIterable {
    case overwrite
    case skip
    case rename           // append "-1", "-2", ...
}

// MARK: - NamingContext

/// All tokens NamingTemplate can substitute.
public struct NamingContext: Sendable {
    public var name: String              // file stem (no extension)
    public var ext: String               // target extension, no dot
    public var date: String              // yyyy-MM-dd
    public var time: String              // HHmmss
    public var width: String             // numeric or ""
    public var height: String
    public var duration: String          // seconds or ""
    public var codec: String             // video+audio codec or ""
    public var preset: String            // preset id or ""
    public var index: Int                // rename collision counter

    public init(
        name: String, ext: String,
        width: Int? = nil, height: Int? = nil,
        duration: Double? = nil, codec: String = "", preset: String = "",
        index: Int = 0
    ) {
        self.name = name
        self.ext = ext
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"; self.date = df.string(from: now)
        df.dateFormat = "HHmmss"; self.time = df.string(from: now)
        self.width = width.map(String.init) ?? ""
        self.height = height.map(String.init) ?? ""
        self.duration = duration.map { String(format: "%.1f", $0) } ?? ""
        self.codec = codec; self.preset = preset; self.index = index
    }
}

// MARK: - NamingTemplate

/// Substitutes tokens like `{name}_{date}_{index}` with values from NamingContext.
public struct NamingTemplate: Sendable, Codable, Equatable {
    public var template: String

    public init(_ template: String = "{name}") {
        self.template = template
    }

    /// Renders a single path component (just the stem, no extension).
    public func render(_ ctx: NamingContext) -> String {
        let tokens: [String: String] = [
            "{name}": sanitize(ctx.name),
            "{ext}": ctx.ext,
            "{date}": ctx.date,
            "{time}": ctx.time,
            "{width}": ctx.width,
            "{height}": ctx.height,
            "{duration}": ctx.duration,
            "{codec}": ctx.codec,
            "{preset}": ctx.preset,
            "{index}": ctx.index == 0 ? "" : "-" + String(ctx.index)
        ]

        var result = template
        for (k, v) in tokens {
            result = result.replacingOccurrences(of: k, with: v)
        }
        // Strip leftover braces (unknown tokens) and collapse underscores
        result = result.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
        // The template itself is user-controlled: remove path separators and
        // control characters so a rule cannot escape the output directory.
        result = sanitize(result)
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_- ."))
        return result.isEmpty ? "untitled" : result
    }

    /// Resolves collisions under `directory` using the policy.
    public func resolve(
        directory: URL, stem: String, ext: String, policy: CollisionPolicy
    ) -> URL {
        let fm = FileManager.default
        var url = directory.appendingPathComponent("\(stem).\(ext)")

        switch policy {
        case .overwrite: return url
        case .skip:
            return fm.fileExists(atPath: url.path) ? URL(fileURLWithPath: "") : url
        case .rename:
            var idx = 1
            while fm.fileExists(atPath: url.path) {
                url = directory.appendingPathComponent("\(stem)-\(idx).\(ext)")
                idx += 1
            }
            return url
        }
    }

    private static let illegalChars = CharacterSet(charactersIn: "\\/:*?\"<>|")
    private func sanitize(_ s: String) -> String {
        var cleaned = s.components(separatedBy: Self.illegalChars).joined()
        cleaned = cleaned.components(separatedBy: .controlCharacters).joined()
        // Prevent `..` from surviving as a traversal segment.
        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: ".")
        }
        return cleaned
    }
}
