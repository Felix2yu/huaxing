import Foundation

// MARK: - Toolchain actor

/// Cached snapshot of every known tool — resolved path + actual version.
public struct ToolchainSnapshot: Sendable {
    public var tools: [Tool: Result<ToolResolution, ToolFailure>]

    public init(tools: [Tool: Result<ToolResolution, ToolFailure>]) {
        self.tools = tools
    }

    public subscript(_ tool: Tool) -> Result<ToolResolution, ToolFailure>? {
        tools[tool]
    }

    public func resolved(_ tool: Tool) throws -> ToolResolution {
        guard let r = tools[tool] else { throw ToolchainError.unknownTool }
        return try r.get()
    }
}

public enum ToolchainError: Error, Sendable {
    case unknownTool
    case toolNotAvailable(Tool, ToolFailure)
}

/// Runs each tool once via `-version` and caches the result. This catches the
/// common Homebrew dyld breakage (`brew upgrade` moves the Cellar but the
/// symlink still points to the old path — dyld then aborts with "Library not
/// loaded").
public actor Toolchain {
    private let userOverrides: [Tool: String]
    private var cache: ToolchainSnapshot?

    public init(userOverrides: [Tool: String] = [:]) {
        self.userOverrides = userOverrides
    }

    /// Clear the cached snapshot; `snapshot()` / `require(_:)` will re-probe.
    public func invalidate() { cache = nil }

    /// Returns the full toolchain snapshot, re-probing on first call or after
    /// `invalidate()`. The probe executes each binary once; expect a few
    /// hundred ms total wall clock.
    public func snapshot() async -> ToolchainSnapshot {
        if let cache { return cache }
        var map: [Tool: Result<ToolResolution, ToolFailure>] = [:]
        for tool in Tool.allCases {
            map[tool] = await probe(tool)
        }
        let snap = ToolchainSnapshot(tools: map)
        cache = snap
        return snap
    }

    /// Convenience — throws a descriptive error if the tool is unavailable.
    public func require(_ tool: Tool) async throws -> ToolResolution {
        let snap = await snapshot()
        switch snap.tools[tool] ?? .failure(.missing) {
        case .success(let r): return r
        case .failure(let f): throw ToolchainError.toolNotAvailable(tool, f)
        }
    }

    // MARK: - Probing

    private func probe(_ tool: Tool) async -> Result<ToolResolution, ToolFailure> {
        let path: String
        if let override = userOverrides[tool] {
            path = override
        } else if let found = ToolLocator.resolve(tool, userOverride: nil) {
            path = found
        } else {
            return .failure(.missing)
        }

        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .failure(.broken(.notExecutable))
        }

        // Execute once. Most tools print version on stderr, ffmpeg to stdout.
        var args: [String]
        if let flag = tool.versionFlag {
            args = [flag]
        } else {
            args = []
        }

        let result = await ProcessRunner.run(ProcessSpec(
            executable: path, arguments: args, timeout: 15
        ))

        // dyld failure detection — stderr contains "dyld" or "Library not loaded".
        let stderr = result.stderr + " " + result.stdout
        let dyldIndicators = ["Library not loaded", "dyld:", "image not found", "symbol not found"]
        for ind in dyldIndicators {
            if stderr.localizedCaseInsensitiveContains(ind) {
                return .failure(.broken(.dyldStale))
            }
        }

        // sips / jxlinfo without args exits non-zero (usage / missing file) —
        // treat that as fine; launch succeeded, presence is sufficient.
        if (tool == .sips || tool == .jxlinfo) && result.exitCode != 0 {
            if result.launched {
                return .success(ToolResolution(path: path, version: .zero))
            }
            return .failure(.broken(.exitNonZero(result.exitCode)))
        }

        if !result.launched {
            return .failure(.broken(.notExecutable))
        }

        // Parse version from whichever stream has it.
        let allOutput = result.stdout + "\n" + result.stderr
        let version = ToolVersion.parse(allOutput) ?? ToolVersion.zero

        if version < tool.minimumVersion {
            return .failure(.versionTooOld(found: version, required: tool.minimumVersion))
        }

        return .success(ToolResolution(path: path, version: version))
    }
}

extension ToolVersion {
    public static let zero = ToolVersion(0, 0, 0)
}
