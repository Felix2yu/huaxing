import Foundation

// MARK: - RuleCondition

public indirect enum RuleCondition: Sendable, Codable, Equatable {
    case all([RuleCondition])
    case any([RuleCondition])
    case not(RuleCondition)
    case mediaKind(is: MediaInfo.Kind)
    case utType(is: String)
    case `extension`(`in`: [String])
    case fileSize(minBytes: Int64? = nil, maxBytes: Int64? = nil)
    case resolution(minWidth: Int? = nil, minHeight: Int? = nil)
    case duration(minSeconds: Double? = nil, maxSeconds: Double? = nil)
    case videoCodec(`in`: [String])
    case audioCodec(`in`: [String])
    case filenameGlob(pattern: String)
    case sourceDirectory(path: String, recursive: Bool = false)
    case hasAlpha(Bool)
}

// MARK: - RuleAction

public struct RuleAction: Sendable, Codable, Equatable {
    public var presetID: String
    public var outputDirectory: String
    public var naming: String
    public var keepMetadata: Bool
    public var collisionPolicy: CollisionPolicy
    public var postProcessing: [PostProcessStep]

    public init(
        presetID: String,
        outputDirectory: String = "~/Desktop",
        naming: String = "{name}",
        keepMetadata: Bool = true,
        collisionPolicy: CollisionPolicy = .overwrite,
        postProcessing: [PostProcessStep] = []
    ) {
        self.presetID = presetID
        self.outputDirectory = outputDirectory
        self.naming = naming
        self.keepMetadata = keepMetadata
        self.collisionPolicy = collisionPolicy
        self.postProcessing = postProcessing
    }
}

public enum PostProcessStep: Sendable, Codable, Equatable {
    case revealInFinder
    case trashSource
    case openResult
}

// MARK: - Rule

public struct Rule: Sendable, Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var priority: Int
    public var createdAt: Date
    public var stopOnMatch: Bool
    public var conditions: RuleCondition
    public var action: RuleAction

    public init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        priority: Int = 0,
        createdAt: Date = Date(),
        stopOnMatch: Bool = true,
        conditions: RuleCondition,
        action: RuleAction
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.createdAt = createdAt
        self.stopOnMatch = stopOnMatch
        self.conditions = conditions
        self.action = action
    }
}

// MARK: - RuleInput

public struct RuleInput: Sendable, Equatable {
    public var url: URL
    public var utType: String?
    public var ext: String
    public var byteSize: Int64?
    public var sourceDirectory: String?
    /// Lazy — populated only when a condition needs it (resolution/duration/codec)
    public var mediaInfo: MediaInfo?

    public init(
        url: URL, utType: String? = nil,
        ext: String? = nil, byteSize: Int64? = nil,
        sourceDirectory: String? = nil, mediaInfo: MediaInfo? = nil
    ) {
        self.url = url
        self.utType = utType
        self.ext = ext ?? url.pathExtension.lowercased()
        self.byteSize = byteSize
        self.sourceDirectory = sourceDirectory
        self.mediaInfo = mediaInfo
    }
}

// MARK: - RuleDecision

public enum RuleDecision: Sendable, Equatable {
    case matched(Rule)
    case noMatch
}

// MARK: - RuleEngine

/// Evaluates rules against an input. Rules are sorted by (priority DESC, createdAt ASC, id)
/// for full determinism.
public enum RuleEngine {

    public static func evaluate(
        _ input: RuleInput,
        rules: [Rule],
        context: EvaluationContext = .default
    ) async -> RuleDecision {
        let sorted = rules
            .filter { $0.enabled }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority > b.priority }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.id < b.id
            }

        for rule in sorted {
            if await match(rule.conditions, input: input, context: context) {
                if rule.stopOnMatch { return .matched(rule) }
                // continue searching for a higher-priority match
                return .matched(rule) // only one matched; stopOnMatch behavior for multiple hits — treat all as matched, first wins by priority
            }
        }
        return .noMatch
    }

    public struct EvaluationContext: Sendable {
        /// Optional provider — the caller (JobQueue, CLI) can plug in a
        /// FFProbe-aware closure so conditions like .resolution trigger probe
        /// lazily instead of unconditionally.
        public var resolveMediaInfo: (@Sendable (URL) async throws -> MediaInfo?)?

        public static let `default` = EvaluationContext()
    }

    private static func match(
        _ cond: RuleCondition,
        input: RuleInput,
        context: EvaluationContext
    ) async -> Bool {
        switch cond {
        case .all(let list):
            for c in list { if !(await match(c, input: input, context: context)) { return false } }
            return true
        case .any(let list):
            for c in list { if await match(c, input: input, context: context) { return true } }
            return false
        case .not(let c):
            return !(await match(c, input: input, context: context))
        case .mediaKind(let kind):
            return await mediaInfo(input, context: context)?.kind == kind
        case .utType(let u):
            return input.utType?.caseInsensitiveCompare(u) == .orderedSame
        case .extension(let arr):
            return arr.contains { $0.lowercased() == input.ext.lowercased() }
        case .fileSize(let min, let max):
            guard let size = input.byteSize else { return false }
            if let min { if size < min { return false } }
            if let max { if size > max { return false } }
            return true
        case .resolution(let minW, let minH):
            guard let mi = await mediaInfo(input, context: context) else { return false }
            if let minW { if (mi.width ?? 0) < minW { return false } }
            if let minH { if (mi.height ?? 0) < minH { return false } }
            return true
        case .duration(let min, let max):
            guard let mi = await mediaInfo(input, context: context),
                  let d = mi.duration else { return false }
            if let min { if d < min { return false } }
            if let max { if d > max { return false } }
            return true
        case .videoCodec(let arr):
            guard let mi = await mediaInfo(input, context: context),
                  let vc = mi.videoCodec else { return false }
            return arr.contains(vc)
        case .audioCodec(let arr):
            guard let mi = await mediaInfo(input, context: context),
                  let ac = mi.audioCodec else { return false }
            return arr.contains(ac)
        case .filenameGlob(let pattern):
            return Glob.match(pattern, input.url.lastPathComponent)
        case .sourceDirectory(let path, let recursive):
            let resolved = (path as NSString).expandingTildeInPath
            let base = URL(fileURLWithPath: resolved).standardizedFileURL.path
            let inputDir = input.url.deletingLastPathComponent().standardizedFileURL.path
            if recursive {
                // Boundary-aware: /a/foo must not match /a/foobar.
                let prefix = base.hasSuffix("/") ? base : base + "/"
                return inputDir == base || inputDir.hasPrefix(prefix)
            } else {
                return inputDir == base
            }
        case .hasAlpha(let want):
            guard let mi = await mediaInfo(input, context: context) else { return false }
            return mi.hasAlpha == want
        }
    }

    private static func mediaInfo(_ input: RuleInput, context: EvaluationContext) async -> MediaInfo? {
        if let cached = input.mediaInfo { return cached }
        if let provider = context.resolveMediaInfo {
            return try? await provider(input.url)
        }
        return nil
    }
}
