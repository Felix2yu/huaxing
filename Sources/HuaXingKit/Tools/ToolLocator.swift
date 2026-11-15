import Foundation

// MARK: - Tool enum

/// External binaries HuaXingKit depends on.
public enum Tool: String, Sendable, CaseIterable, Codable {
    case ffmpeg, ffprobe, cjxl, djxl, jxlinfo, cwebp, dwebp, sips

    /// Tools that every conversion path depends on. The rest are optional and
    /// only needed for specific image pipelines, so a missing one is a warning.
    public var isRequired: Bool {
        self == .ffmpeg || self == .ffprobe
    }

    /// Minimum acceptable version for each tool.
    public var minimumVersion: ToolVersion {
        switch self {
        case .ffmpeg, .ffprobe: return ToolVersion(6, 0, 0)
        case .cjxl, .djxl: return ToolVersion(0, 10, 0)
        case .jxlinfo: return ToolVersion(0, 0, 0) // no version flag available
        case .cwebp, .dwebp: return ToolVersion(1, 0, 0)
        case .sips: return ToolVersion(0, 0, 0) // system tool, always fine
        }
    }

    /// Optional version flag — nil means the tool doesn't support a version flag
    /// (jxlinfo, sips) and presence is sufficient.
    public var versionFlag: String? {
        switch self {
        case .sips, .jxlinfo: return nil
        case .cjxl, .djxl: return "--version"
        default: return "-version"
        }
    }
}

public struct ToolVersion: Sendable, Codable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    public static func < (l: ToolVersion, r: ToolVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// Best-effort parser: finds the first digit triplet in the string.
    public static func parse(_ text: String) -> ToolVersion? {
        let ns = text as NSString
        // Match X.Y.Z or X.Y
        let pattern = "(\\d+)\\.(\\d+)(?:\\.(\\d+))?"
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let major = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let minor = Int(ns.substring(with: m.range(at: 2))) ?? 0
        let patch = m.range(at: 3).location != NSNotFound
            ? Int(ns.substring(with: m.range(at: 3))) ?? 0 : 0
        return ToolVersion(major, minor, patch)
    }
}

// MARK: - ToolResolution

/// Result of locating a tool on disk.
public struct ToolResolution: Sendable, Equatable {
    public let path: String
    public let version: ToolVersion

    public init(path: String, version: ToolVersion) {
        self.path = path; self.version = version
    }
}

/// Why a tool could not be resolved.
public enum ToolFailure: Sendable, Equatable, Error, CustomStringConvertible {
    case missing
    case broken(BreakReason)
    case versionTooOld(found: ToolVersion, required: ToolVersion)

    public enum BreakReason: Sendable, Equatable {
        case dyldStale           // stderr contains "dyld" or "Library not loaded"
        case notExecutable
        case exitNonZero(Int32)
    }

    public var description: String {
        switch self {
        case .missing: return "not found"
        case .broken(.dyldStale): return "dyld load failed (likely Cellar symlink stale)"
        case .broken(.notExecutable): return "not executable"
        case .broken(.exitNonZero(let c)): return "unexpected exit code \(c)"
        case .versionTooOld(let f, let r): return "version \(f) < required \(r)"
        }
    }
}

// MARK: - ToolLocator

/// Searchs for a tool on disk without executing it.
public enum ToolLocator {
    /// Standard install directories, checked **before** the process PATH.
    ///
    /// A GUI app launched by LaunchServices inherits a minimal PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`) that omits Homebrew entirely, so a
    /// PATH-only lookup would report brew-installed ffmpeg/ffprobe as missing.
    /// These entries are directories — `appendingPathComponent` adds the tool
    /// name. (Previously they were full file paths and got the name appended a
    /// second time, e.g. `/opt/homebrew/bin/ffmpeg/ffmpeg`, which made every
    /// hardcoded fallback dead code.)
    private static let standardDirectories = [
        "/opt/homebrew/bin",   // Apple Silicon Homebrew
        "/usr/local/bin",      // Intel Homebrew / manual installs
        "/usr/bin",            // system tools, e.g. sips
    ]

    /// Search order: explicit user override → standard install directories →
    /// process PATH. The override is a complete executable path, not a directory.
    public static func resolve(_ tool: Tool, userOverride: String? = nil) -> String? {
        resolve(
            tool,
            userOverride: userOverride,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"] ?? ""
        )
    }

    /// Test seam — simulates a different PATH (e.g. the minimal GUI one) without
    /// mutating the process environment.
    static func resolve(
        _ tool: Tool,
        userOverride: String? = nil,
        pathEnvironment: String
    ) -> String? {
        if let userOverride {
            let p = (userOverride as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }

        let pathDirs = pathEnvironment.split(separator: ":").map(String.init)

        for dir in standardDirectories + pathDirs where !dir.isEmpty {
            let p = (dir as NSString).appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}
