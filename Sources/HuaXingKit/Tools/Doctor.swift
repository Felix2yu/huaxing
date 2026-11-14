import Foundation

// MARK: - Diagnostic

/// One line of output from `Doctor.diagnose()`.
public struct Diagnostic: Sendable, Equatable, Identifiable {
    public enum Severity: Sendable, Equatable { case ok, warning, error }
    public var id: Tool { tool }  // 每轮 diagnose() 每个 tool 一条
    public var severity: Severity
    public var tool: Tool
    public var message: String
    /// Shell command the user can run to fix the issue (e.g. `brew reinstall ffmpeg`).
    public var installCommand: String?
}

/// Aggregated health of a diagnostic round. Only `.error` entries mean the
/// toolchain is unusable; optional tools that are missing/broken are warnings
/// and must never turn the whole toolchain red.
public struct DiagnosticSummary: Sendable, Equatable {
    public var errors: Int
    public var warnings: Int
    /// True when every required tool is usable — optional warnings are fine.
    public var ok: Bool { errors == 0 }

    public init(errors: Int, warnings: Int) {
        self.errors = errors
        self.warnings = warnings
    }
}

// MARK: - Doctor

public enum Doctor {
    /// Probes every known tool and returns a list of diagnostics. When all tools
    /// are healthy, every entry has `.ok` severity.
    public static func diagnose() async -> [Diagnostic] {
        let snap = await Toolchain().snapshot()
        return diagnose(snapshot: snap)
    }

    /// Single source of truth for CLI + GUI: warnings never make `ok` false.
    public static func summary(_ diagnostics: [Diagnostic]) -> DiagnosticSummary {
        DiagnosticSummary(
            errors: diagnostics.filter { $0.severity == .error }.count,
            warnings: diagnostics.filter { $0.severity == .warning }.count
        )
    }

    public static func hasError(_ diagnostics: [Diagnostic]) -> Bool {
        diagnostics.contains { $0.severity == .error }
    }

    /// Reuses an existing snapshot — avoids probing the whole toolchain twice
    /// when the caller already has one (AppModel, CLI).
    public static func diagnose(snapshot: ToolchainSnapshot) -> [Diagnostic] {
        Tool.allCases.map { tool in
            switch snapshot.tools[tool] ?? .failure(.missing) {
            case .success(let res):
                Diagnostic(
                    severity: .ok,
                    tool: tool,
                    message: "Found \(res.path) (v\(res.version))",
                    installCommand: nil
                )
            case .failure(.missing):
                Diagnostic(
                    severity: tool.isRequired ? .error : .warning,
                    tool: tool,
                    message: tool.isRequired
                        ? "Not found on PATH"
                        : "Optional tool not installed — only affects some formats",
                    installCommand: installCommand(for: tool)
                )
            case .failure(.broken(.dyldStale)):
                Diagnostic(
                    severity: tool.isRequired ? .error : .warning,
                    tool: tool,
                    message: "dyld load failed — Cellar path stale",
                    installCommand: installCommand(for: tool)
                )
            case .failure(.broken(.notExecutable)):
                Diagnostic(
                    severity: tool.isRequired ? .error : .warning,
                    tool: tool,
                    message: "Path exists but is not executable",
                    installCommand: nil
                )
            case .failure(.broken(.exitNonZero(let code))):
                Diagnostic(
                    severity: tool.isRequired ? .error : .warning,
                    tool: tool,
                    message: "Unexpected exit code \(code)",
                    installCommand: installCommand(for: tool)
                )
            case .failure(.versionTooOld(let found, let required)):
                Diagnostic(
                    severity: tool.isRequired ? .error : .warning,
                    tool: tool,
                    message: "v\(found) < required v\(required)",
                    installCommand: installCommand(for: tool)
                )
            }
        }
    }

    private static func installCommand(for tool: Tool) -> String? {
        switch tool {
        case .ffmpeg, .ffprobe: return "brew reinstall ffmpeg"
        case .cjxl, .djxl, .jxlinfo: return "brew reinstall jpeg-xl"
        case .cwebp, .dwebp: return "brew reinstall webp"
        case .sips: return nil // system tool
        }
    }
}
