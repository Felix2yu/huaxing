import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - RuleExecutionPlan

/// A fully resolved rule decision: which preset to apply, where the output
/// goes, and what to do after the conversion finishes.
public struct RuleExecutionPlan: Sendable, Equatable {
    public var ruleID: String
    public var ruleName: String
    public var presetID: String
    public var outputURL: URL
    public var keepMetadata: Bool
    public var collisionPolicy: CollisionPolicy
    public var postProcessing: [PostProcessStep]

    public init(
        ruleID: String,
        ruleName: String,
        presetID: String,
        outputURL: URL,
        keepMetadata: Bool,
        collisionPolicy: CollisionPolicy,
        postProcessing: [PostProcessStep]
    ) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.presetID = presetID
        self.outputURL = outputURL
        self.keepMetadata = keepMetadata
        self.collisionPolicy = collisionPolicy
        self.postProcessing = postProcessing
    }
}

// MARK: - Errors

public enum RuleExecutionError: Error, Sendable, LocalizedError {
    case presetMissing(String)
    case outputAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .presetMissing(let id):
            return "规则引用的预设不存在：\(id)"
        case .outputAlreadyExists(let path):
            return "输出文件已存在，已按“跳过”策略略过：\(path)"
        }
    }
}

// MARK: - RuleExecutor

/// Shared rule→plan logic used by both the CLI and the GUI. Rendering and
/// collision handling live here so both front-ends behave identically.
public enum RuleExecutor {

    /// Builds the concrete output path for a matched rule.
    ///
    /// - Parameters:
    ///   - occupied: paths already reserved earlier in the same batch, so two
    ///     inputs can never resolve to the same output.
    public static func makePlan(
        input: URL,
        mediaInfo: MediaInfo?,
        rule: Rule,
        preset: Preset,
        occupied: Set<String> = []
    ) throws -> RuleExecutionPlan {
        // A rule may leave these fields blank. The preset is then the source of
        // truth — never let an empty string silently resolve to the process's
        // current working directory.
        let outputDirectory = firstNonEmpty(
            rule.action.outputDirectory, preset.outputDirectory, "~/Desktop"
        )
        let directory = URL(
            fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath,
            isDirectory: true
        )

        let ext = preset.outputExtension
        let codec = preset.video?.encoder.rawValue
            ?? preset.audio?.encoder.rawValue
            ?? preset.image?.target.rawValue
            ?? ""

        let ctx = NamingContext(
            name: input.deletingPathExtension().lastPathComponent,
            ext: ext,
            width: mediaInfo?.width,
            height: mediaInfo?.height,
            duration: mediaInfo?.duration,
            codec: codec,
            preset: preset.id
        )

        let naming = firstNonEmpty(rule.action.naming, preset.naming, "{name}")
        let rendered = NamingTemplate(naming).render(ctx)
        let fileName = rendered.hasSuffix(".\(ext)") ? rendered : "\(rendered).\(ext)"

        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(fileName)
        let stem = candidate.deletingPathExtension().lastPathComponent

        func isTaken(_ url: URL) -> Bool {
            fm.fileExists(atPath: url.path) || occupied.contains(url.standardizedFileURL.path)
        }

        switch rule.action.collisionPolicy {
        case .overwrite:
            // Overwrite an existing file on disk (ffmpeg runs with -y, image
            // pipelines clear the stale output), but never let two inputs in
            // the same batch fight over the very same output path.
            var index = 1
            while occupied.contains(candidate.standardizedFileURL.path) {
                candidate = directory.appendingPathComponent("\(stem)-\(index).\(ext)")
                index += 1
            }
        case .rename:
            var index = 1
            while isTaken(candidate) {
                candidate = directory.appendingPathComponent("\(stem)-\(index).\(ext)")
                index += 1
            }
        case .skip:
            if isTaken(candidate) {
                throw RuleExecutionError.outputAlreadyExists(candidate.path)
            }
        }

        return RuleExecutionPlan(
            ruleID: rule.id,
            ruleName: rule.name,
            presetID: preset.id,
            outputURL: candidate,
            keepMetadata: rule.action.keepMetadata,
            collisionPolicy: rule.action.collisionPolicy,
            postProcessing: rule.action.postProcessing
        )
    }

    private static func firstNonEmpty(_ candidates: String...) -> String {
        for value in candidates {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    /// Executes `revealInFinder` / `openResult` / `trashSource` after a
    /// successful conversion.
    public static func performPostProcessing(
        _ steps: [PostProcessStep],
        output: URL,
        source: URL
    ) async {
        guard !steps.isEmpty else { return }

        #if canImport(AppKit)
        await MainActor.run {
            for step in steps {
                switch step {
                case .revealInFinder:
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                case .openResult:
                    NSWorkspace.shared.open(output)
                case .trashSource:
                    try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
                }
            }
        }
        #endif
    }
}
