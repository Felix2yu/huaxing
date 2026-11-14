import Foundation
import Testing
@testable import HuaXingKit

// MARK: - CompatibilityMatrix

struct CompatibilityMatrixTests {

    private func snapshot(missing: Set<Tool> = []) -> ToolchainSnapshot {
        var tools: [Tool: Result<ToolResolution, ToolFailure>] = [:]
        for tool in Tool.allCases {
            if missing.contains(tool) {
                tools[tool] = .failure(.missing)
            } else {
                tools[tool] = .success(
                    ToolResolution(path: "/usr/bin/\(tool.rawValue)", version: ToolVersion(9, 0, 0))
                )
            }
        }
        return ToolchainSnapshot(tools: tools)
    }

    private func videoPreset(container: Container, encoder: VideoEncoder, audio: AudioEncoder? = .aac) -> Preset {
        Preset(
            name: "test", kind: .video, container: container,
            video: VideoSettings(encoder: encoder),
            audio: audio.map { AudioSettings(encoder: $0) }
        )
    }

    @Test("WebM rejects H.264")
    func webmRejectsH264() {
        let preset = videoPreset(container: .webm, encoder: .libx264)
        let violations = CompatibilityMatrix.validate(
            preset: preset, source: MediaInfo(kind: .video), toolchain: snapshot()
        )
        #expect(violations.contains { $0.category == .containerCodecMismatch })
    }

    @Test("WebM accepts VP9 + Opus")
    func webmAcceptsVP9Opus() {
        let preset = videoPreset(container: .webm, encoder: .libvpx_vp9, audio: .libopus)
        let violations = CompatibilityMatrix.validate(
            preset: preset, source: MediaInfo(kind: .video), toolchain: snapshot()
        )
        #expect(violations.isEmpty)
    }

    @Test("M4A with AAC is valid (no false positive)")
    func m4aAACIsValid() {
        let preset = Preset(
            name: "audio", kind: .audio, container: .m4a,
            audio: AudioSettings(encoder: .aac, bitrate: "192k")
        )
        let violations = CompatibilityMatrix.validate(
            preset: preset, source: MediaInfo(kind: .video), toolchain: snapshot()
        )
        #expect(violations.isEmpty)
    }

    @Test("MP3 container rejects AAC")
    func mp3RejectsAAC() {
        let preset = Preset(
            name: "audio", kind: .audio, container: .mp3,
            audio: AudioSettings(encoder: .aac)
        )
        let violations = CompatibilityMatrix.validate(
            preset: preset, source: MediaInfo(kind: .audio), toolchain: snapshot()
        )
        #expect(violations.contains { $0.category == .containerCodecMismatch })
    }

    @Test("Audio preset on a video source may extract audio")
    func audioPresetOnVideoSource() {
        let preset = Preset(
            name: "audio", kind: .audio, container: .mp3,
            audio: AudioSettings(encoder: .libmp3lame)
        )
        let source = MediaInfo(kind: .video, videoCodec: "h264", audioCodec: "aac")
        let violations = CompatibilityMatrix.validate(
            preset: preset, source: source, toolchain: snapshot()
        )
        #expect(violations.isEmpty)
    }

    @Test("10-bit input with h264_videotoolbox is rejected")
    func tenBitH264VT() {
        let preset = videoPreset(container: .mp4, encoder: .h264_videotoolbox)
        let source = MediaInfo(kind: .video, pixFmt: "yuv420p10le")
        let violations = CompatibilityMatrix.validate(
            preset: preset, source: source, toolchain: snapshot()
        )
        #expect(violations.contains { $0.category == .pixFmtEncoderMismatch })
    }

    @Test("Missing cjxl is reported for JXL preset")
    func missingJXL() {
        let preset = Preset(
            name: "img", kind: .image, container: .mp4,
            image: ImageSettings(target: .jxl)
        )
        let violations = CompatibilityMatrix.validate(
            preset: preset, source: MediaInfo(kind: .image), toolchain: snapshot(missing: [.cjxl])
        )
        #expect(violations.contains { $0.category == .toolUnavailable })
    }
}

// MARK: - FFmpegCommandBuilder

struct FFmpegCommandBuilderTests {

    private let input = URL(fileURLWithPath: "/tmp/in.mp4")
    private let output = URL(fileURLWithPath: "/tmp/out.mp4")

    @Test("Audio extraction always passes -vn")
    func audioAlwaysDropsVideo() {
        let preset = Preset(
            name: "m4a", kind: .audio, container: .m4a,
            audio: AudioSettings(encoder: .aac, bitrate: "192k", channels: 1)
        )
        let args = FFmpegCommandBuilder.audioArguments(input: input, output: output, preset: preset)
        #expect(args.contains("-vn"))
        #expect(args.contains("aac"))
        #expect(args.contains("1"))
    }

    @Test("Plain software scale is even-dimension safe")
    func plainScaleIsEven() {
        let preset = Preset(
            name: "v", kind: .video, container: .mp4,
            video: VideoSettings(
                encoder: .libx264, crf: 23,
                maxWidth: 1280, maxHeight: 720
            )
        )
        let args = FFmpegCommandBuilder.videoArguments(input: input, output: output, preset: preset)
        let vf = args.first { $0.hasPrefix("scale=") }
        #expect(vf?.contains("force_divisible_by=2") == true)
        #expect(!args.contains("videotoolbox_vld"))
    }

    @Test("VT scale uses videotoolbox_vld and scale_vt")
    func vtScaleChain() {
        let preset = Preset(
            name: "v", kind: .video, container: .mp4,
            video: VideoSettings(
                encoder: .hevc_videotoolbox, bitrate: "3M",
                maxWidth: 1280, maxHeight: 720, scaleVt: true
            )
        )
        let args = FFmpegCommandBuilder.videoArguments(input: input, output: output, preset: preset)
        #expect(args.contains("videotoolbox_vld"))
        #expect(args.contains { $0.hasPrefix("scale_vt=") })
    }

    @Test("VT without scale does not force videotoolbox_vld")
    func vtWithoutScaleKeepsSoftwareFrames() {
        let preset = Preset(
            name: "v", kind: .video, container: .mp4,
            video: VideoSettings(encoder: .hevc_videotoolbox, bitrate: "3M", scaleVt: true)
        )
        let args = FFmpegCommandBuilder.videoArguments(input: input, output: output, preset: preset)
        #expect(!args.contains("videotoolbox_vld"))
    }

    @Test("WebM defaults audio to Opus")
    func webmDefaultAudioOpus() {
        let preset = Preset(
            name: "v", kind: .video, container: .webm,
            video: VideoSettings(encoder: .libvpx_vp9)
        )
        let args = FFmpegCommandBuilder.videoArguments(input: input, output: output, preset: preset)
        #expect(args.contains("libopus"))
    }
}

// MARK: - NamingTemplate

struct NamingTemplateTests {

    @Test("Rendered names cannot escape the output directory")
    func stripsTraversal() {
        let tpl = NamingTemplate("../../{name}")
        let ctx = NamingContext(name: "source", ext: "mp4")
        let name = tpl.render(ctx)
        #expect(!name.contains(".."))
        #expect(!name.contains("/"))
    }

    @Test("Unknown tokens are removed")
    func removesUnknownTokens() {
        let tpl = NamingTemplate("{unknown}_{name}")
        let ctx = NamingContext(name: "source", ext: "mp4")
        #expect(tpl.render(ctx) == "source")
    }
}

// MARK: - RuleEngine

struct RuleEngineTests {

    private let action = RuleAction(presetID: "hevc-1080p")

    private func cameraInput(width: Int, name: String = "IMG_1000.mp4") -> RuleInput {
        RuleInput(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            mediaInfo: MediaInfo(kind: .video, width: width, height: 1080, videoCodec: "h264")
        )
    }

    @Test("Default camera rule matches 1080p IMG_* video")
    func defaultRuleMatches() async {
        let rule = Rule(
            id: "default-hevc-camera",
            name: "相机视频转 HEVC",
            priority: 100,
            conditions: .all([
                .mediaKind(is: .video),
                .extension(in: ["mp4", "mov"]),
                .resolution(minWidth: 1920),
                .filenameGlob(pattern: "IMG_*")
            ]),
            action: action
        )
        let decision = await RuleEngine.evaluate(cameraInput(width: 1920), rules: [rule])
        #expect(decision == .matched(rule))
    }

    @Test("Glob is case-insensitive")
    func globCaseInsensitive() async {
        let rule = Rule(
            name: "lowercase",
            conditions: .filenameGlob(pattern: "img_*"),
            action: action
        )
        let decision = await RuleEngine.evaluate(cameraInput(width: 1920), rules: [rule])
        #expect(decision == .matched(rule))
    }

    @Test("Source directory matching is path-boundary aware")
    func sourceDirectoryBoundary() async {
        let rule = Rule(
            name: "dir",
            conditions: .sourceDirectory(path: "/tmp/foo", recursive: true),
            action: action
        )
        let sibling = RuleInput(
            url: URL(fileURLWithPath: "/tmp/foobar/clip.mp4"),
            mediaInfo: MediaInfo(kind: .video)
        )
        let child = RuleInput(
            url: URL(fileURLWithPath: "/tmp/foo/sub/clip.mp4"),
            mediaInfo: MediaInfo(kind: .video)
        )
        let siblingDecision = await RuleEngine.evaluate(sibling, rules: [rule])
        let childDecision = await RuleEngine.evaluate(child, rules: [rule])
        #expect(siblingDecision == .noMatch)
        #expect(childDecision == .matched(rule))
    }
}
