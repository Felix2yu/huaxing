import Foundation

// MARK: - RuleStore

/// Persists Rule[] via JSONStore, facade used by CLI and GUI alike.
/// Both sides read/write the same file — changes from either are picked up
/// by a subsequent process launch or a manual `reload()`.
public final class RuleStore: @unchecked Sendable {
    private let store: JSONStore<[Rule]>

    public init(url: URL = AppPaths.rulesFile) {
        self.store = JSONStore(url: url, schema: 1)
    }

    public func load() throws -> [Rule] {
        try store.load() ?? Self.defaultRules()
    }

    public func save(_ rules: [Rule]) throws {
        try store.save(rules)
    }

    public func upsert(_ rule: Rule, in rules: [Rule]) -> [Rule] {
        var copy = rules
        if let idx = copy.firstIndex(where: { $0.id == rule.id }) {
            copy[idx] = rule
        } else {
            copy.append(rule)
        }
        return copy
    }

    public func delete(id: String, in rules: [Rule]) -> [Rule] {
        rules.filter { $0.id != id }
    }

    public func find(id: String, in rules: [Rule]) -> Rule? {
        rules.first { $0.id == id }
    }

    private static func defaultRules() -> [Rule] {
        [
            Rule(
                id: "default-hevc-camera",
                name: "相机视频转 HEVC",
                priority: 100,
                conditions: .all([
                    .mediaKind(is: .video),
                    .extension(in: ["mp4", "mov"]),
                    .resolution(minWidth: 1920),
                    .filenameGlob(pattern: "IMG_*")
                ]),
                action: RuleAction(
                    presetID: "hevc-1080p",
                    outputDirectory: "~/Movies/Converted",
                    naming: "{name}_{date}",
                    keepMetadata: true
                )
            )
        ]
    }
}

// MARK: - PresetStore

public final class PresetStore: @unchecked Sendable {
    private let store: JSONStore<[Preset]>

    public init(url: URL = AppPaths.presetsFile) {
        self.store = JSONStore(url: url, schema: 1)
    }

    public func load() throws -> [Preset] {
        try store.load() ?? Self.defaultPresets()
    }

    public func save(_ presets: [Preset]) throws {
        try store.save(presets)
    }

    private static func defaultPresets() -> [Preset] {
        [
            Preset(
                id: "hevc-1080p",
                name: "HEVC 1080p",
                kind: .video,
                container: .mp4,
                video: VideoSettings(encoder: .hevc_videotoolbox, bitrate: "3M", scaleVt: true),
                audio: AudioSettings(encoder: .aac, bitrate: "128k"),
                naming: "{name}_{date}",
                outputDirectory: "~/Movies/Converted"
            ),
            Preset(
                id: "h264-web",
                name: "H.264 Web",
                kind: .video,
                container: .mp4,
                video: VideoSettings(encoder: .libx264, crf: 23, preset: "medium"),
                audio: AudioSettings(encoder: .aac, bitrate: "128k"),
                naming: "{name}-web",
                outputDirectory: "~/Desktop"
            )
        ]
    }
}
