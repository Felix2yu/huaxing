import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import HuaXingKit

// MARK: - Doctor severity

struct DoctorSeverityTests {

    private func snapshot(
        missing: Set<Tool> = [],
        brokenRequired: Set<Tool> = []
    ) -> ToolchainSnapshot {
        var tools: [Tool: Result<ToolResolution, ToolFailure>] = [:]
        for tool in Tool.allCases {
            if missing.contains(tool) {
                tools[tool] = .failure(.missing)
            } else if brokenRequired.contains(tool) {
                tools[tool] = .failure(.broken(.exitNonZero(1)))
            } else {
                tools[tool] = .success(
                    ToolResolution(path: "/usr/bin/\(tool.rawValue)", version: ToolVersion(9, 0, 0))
                )
            }
        }
        return ToolchainSnapshot(tools: tools)
    }

    @Test("djxl/dwebp/jxlinfo/sips 缺失只产生 warning")
    func optionalToolsAreWarnings() {
        let missing: Set<Tool> = [.djxl, .dwebp, .jxlinfo, .sips]
        let diags = Doctor.diagnose(snapshot: snapshot(missing: missing))
        let health = Doctor.summary(diags)
        #expect(health.errors == 0)
        #expect(health.warnings == missing.count)
        #expect(health.ok)
        #expect(!Doctor.hasError(diags))
        #expect(diags.filter { missing.contains($0.tool) }
            .allSatisfy { $0.severity == .warning })
    }

    @Test("必需工具缺失是 error")
    func requiredToolMissingIsError() {
        let diags = Doctor.diagnose(snapshot: snapshot(missing: [.ffprobe]))
        let health = Doctor.summary(diags)
        #expect(health.errors == 1)
        #expect(!health.ok)
    }

    @Test("必需工具损坏也是 error，可选工具损坏仍是 warning")
    func brokenRequiredToolIsError() {
        let required = Doctor.diagnose(snapshot: snapshot(brokenRequired: [.ffmpeg]))
        #expect(Doctor.summary(required).errors == 1)

        let optional = Doctor.diagnose(snapshot: snapshot(brokenRequired: [.djxl]))
        #expect(Doctor.summary(optional).errors == 0)
        #expect(Doctor.summary(optional).warnings == 1)
    }
}

// MARK: - RuleExecutor plan / collision / naming

struct RuleExecutorTests {

    private let preset = Preset(
        id: "test-preset", name: "测试", kind: .video, container: .mp4,
        video: VideoSettings(encoder: .libx264)
    )

    private func makeRule(
        dir: String,
        policy: CollisionPolicy,
        naming: String = "{name}"
    ) -> Rule {
        Rule(
            name: "规则 A",
            conditions: .mediaKind(is: .video),
            action: RuleAction(
                presetID: preset.id,
                outputDirectory: dir,
                naming: naming,
                keepMetadata: false,
                collisionPolicy: policy,
                postProcessing: [.revealInFinder, .trashSource]
            )
        )
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huaxing-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let source = URL(fileURLWithPath: "/tmp/IMG_0001.mp4")

    @Test("overwrite 保留原路径，rename 追加 -1")
    func overwriteAndRename() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("old".utf8).write(to: dir.appendingPathComponent("IMG_0001.mp4"))

        let overwrite = try RuleExecutor.makePlan(
            input: source, mediaInfo: nil,
            rule: makeRule(dir: dir.path, policy: .overwrite), preset: preset
        )
        #expect(overwrite.outputURL.lastPathComponent == "IMG_0001.mp4")

        let rename = try RuleExecutor.makePlan(
            input: source, mediaInfo: nil,
            rule: makeRule(dir: dir.path, policy: .rename), preset: preset
        )
        #expect(rename.outputURL.lastPathComponent == "IMG_0001-1.mp4")
    }

    @Test("skip 策略在输出已存在时抛出，不静默覆盖")
    func skipPolicy() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("old".utf8).write(to: dir.appendingPathComponent("IMG_0001.mp4"))

        #expect(throws: RuleExecutionError.self) {
            _ = try RuleExecutor.makePlan(
                input: source, mediaInfo: nil,
                rule: makeRule(dir: dir.path, policy: .skip), preset: preset
            )
        }
    }

    @Test("overwrite 不会让同一批次的两个任务写同一个文件")
    func overwriteRespectsOccupied() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try RuleExecutor.makePlan(
            input: source, mediaInfo: nil,
            rule: makeRule(dir: dir.path, policy: .overwrite), preset: preset
        )
        let second = try RuleExecutor.makePlan(
            input: source, mediaInfo: nil,
            rule: makeRule(dir: dir.path, policy: .overwrite), preset: preset,
            occupied: [first.outputURL.standardizedFileURL.path]
        )
        #expect(second.outputURL.lastPathComponent == "IMG_0001-1.mp4")
    }

    @Test("命名模板拿到 ffprobe 的 width/height/duration")
    func namingUsesProbedMediaInfo() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = MediaInfo(kind: .video, duration: 12.3, width: 1920, height: 1080)
        let plan = try RuleExecutor.makePlan(
            input: URL(fileURLWithPath: "/tmp/clip.mp4"),
            mediaInfo: info,
            rule: makeRule(
                dir: dir.path, policy: .rename,
                naming: "{name}_{width}x{height}_{duration}"
            ),
            preset: preset
        )
        #expect(plan.outputURL.lastPathComponent == "clip_1920x1080_12.3.mp4")
    }

    @Test("plan 携带预设、keepMetadata、冲突策略与后处理")
    func planCarriesRuleActions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rule = makeRule(dir: dir.path, policy: .skip)
        let plan = try RuleExecutor.makePlan(
            input: source, mediaInfo: nil, rule: rule, preset: preset
        )
        #expect(plan.ruleID == rule.id)
        #expect(plan.presetID == preset.id)
        #expect(plan.keepMetadata == false)
        #expect(plan.collisionPolicy == .skip)
        #expect(plan.postProcessing == [.revealInFinder, .trashSource])
    }

    @Test("规则动作留空时回退到预设的输出目录与命名模板")
    func blankRuleActionFallsBackToPreset() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configured = Preset(
            id: "configured", name: "带目录的预设", kind: .image, container: .mp4,
            image: ImageSettings(target: .webp),
            naming: "{name}_from-preset",
            outputDirectory: dir.path
        )
        let rule = Rule(
            name: "空白动作",
            conditions: .extension(in: ["png"]),
            action: RuleAction(
                presetID: configured.id,
                outputDirectory: "   ",
                naming: "",
                collisionPolicy: .rename
            )
        )
        let plan = try RuleExecutor.makePlan(
            input: URL(fileURLWithPath: "/tmp/photo.png"),
            mediaInfo: MediaInfo(kind: .image, width: 8, height: 8),
            rule: rule, preset: configured
        )
        #expect(plan.outputURL.deletingLastPathComponent().path == dir.path)
        #expect(plan.outputURL.lastPathComponent == "photo_from-preset.webp")
    }
}

// MARK: - Image metadata loss reporting

struct ImageMetadataTests {

    private enum TestError: Error { case imageCreation }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("huaxing-img-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeImage(to url: URL, type: String, exif: Bool) throws {
        guard let ctx = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError.imageCreation }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)
        else { throw TestError.imageCreation }

        let props: CFDictionary? = exif
            ? ([kCGImagePropertyExifDictionary:
                    [kCGImagePropertyExifUserComment: "huaxing-test"]] as CFDictionary)
            : nil
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else { throw TestError.imageCreation }
    }

    @Test("无 EXIF 的 PNG 不算有可保留元数据")
    func plainPNGHasNoMetadata() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plain.png")
        try writeImage(to: url, type: "public.png", exif: false)
        #expect(ImageIOBridge.hasPreservableMetadata(of: url) == false)
        // metadata(of:) is NOT a proxy: it returns a dictionary even here.
        #expect(ImageIOBridge.metadata(of: url) != nil)
    }

    @Test("带 EXIF 的 JPEG 有可保留元数据")
    func jpegWithExifHasMetadata() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tagged.jpg")
        try writeImage(to: url, type: "public.jpeg", exif: true)
        #expect(ImageIOBridge.hasPreservableMetadata(of: url) == true)
    }

    @Test("WebP 直接读原图转码不误报元数据丢失")
    func webpDirectDoesNotClaimMetadataLoss() async throws {
        guard let cwebp = ToolLocator.resolve(.cwebp) else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("plain.png")
        try writeImage(to: png, type: "public.png", exif: false)
        let output = dir.appendingPathComponent("plain.webp")

        let snapshot = ToolchainSnapshot(tools: [
            .cwebp: .success(ToolResolution(path: cwebp, version: ToolVersion(1, 0, 0)))
        ])
        let result = try await ImagePipeline(toolchain: snapshot).run(
            input: png, output: output,
            settings: ImageSettings(target: .webp, quality: 90, lossless: false),
            keepMetadata: true
        )
        #expect(result.metadataLost == false)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test("JXL 直接读原图转码不误报元数据丢失")
    func jxlDirectDoesNotClaimMetadataLoss() async throws {
        guard let cjxl = ToolLocator.resolve(.cjxl) else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("plain.png")
        try writeImage(to: png, type: "public.png", exif: false)
        let output = dir.appendingPathComponent("plain.jxl")

        // 快照里故意不放 ffmpeg/ffprobe：图片管线只依赖 cjxl。
        let snapshot = ToolchainSnapshot(tools: [
            .cjxl: .success(ToolResolution(path: cjxl, version: ToolVersion(0, 10, 0)))
        ])
        let result = try await ImagePipeline(toolchain: snapshot).run(
            input: png, output: output,
            settings: ImageSettings(target: .jxl, quality: 90, lossless: false),
            keepMetadata: true
        )
        #expect(result.metadataLost == false)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test("确有 EXIF 且必须走 PNG 中间图时仍如实报告元数据丢失")
    func exifViaIntermediateReportsLoss() async throws {
        guard let cwebp = ToolLocator.resolve(.cwebp) else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("tagged.jpg")
        try writeImage(to: jpeg, type: "public.jpeg", exif: true)
        #expect(ImageIOBridge.hasPreservableMetadata(of: jpeg))
        let output = dir.appendingPathComponent("resized.webp")

        let snapshot = ToolchainSnapshot(tools: [
            .cwebp: .success(ToolResolution(path: cwebp, version: ToolVersion(1, 0, 0)))
        ])
        let result = try await ImagePipeline(toolchain: snapshot).run(
            input: jpeg, output: output,
            settings: ImageSettings(target: .webp, quality: 90, maxWidth: 4, lossless: false),
            keepMetadata: true
        )
        #expect(result.metadataLost == true)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}

// MARK: - Image presets must not require ffmpeg

struct ImageToolDependencyTests {

    private func snapshotWithoutFFmpeg(imageTool: Tool) -> ToolchainSnapshot {
        var tools: [Tool: Result<ToolResolution, ToolFailure>] = [:]
        for tool in Tool.allCases { tools[tool] = .failure(.missing) }
        tools[imageTool] = .success(
            ToolResolution(path: "/opt/homebrew/bin/\(imageTool.rawValue)", version: ToolVersion(9, 0, 0))
        )
        return ToolchainSnapshot(tools: tools)
    }

    @Test("图片预设在 ffmpeg/ffprobe 全缺失时没有工具相关违规")
    func imagePresetDoesNotRequireFFmpeg() {
        let webp = Preset(
            name: "WebP", kind: .image, container: .mp4,
            image: ImageSettings(target: .webp)
        )
        #expect(CompatibilityMatrix.validate(
            preset: webp, source: MediaInfo(kind: .image),
            toolchain: snapshotWithoutFFmpeg(imageTool: .cwebp)
        ).isEmpty)

        let jxl = Preset(
            name: "JXL", kind: .image, container: .mp4,
            image: ImageSettings(target: .jxl)
        )
        #expect(CompatibilityMatrix.validate(
            preset: jxl, source: MediaInfo(kind: .image),
            toolchain: snapshotWithoutFFmpeg(imageTool: .cjxl)
        ).isEmpty)
    }

    @Test("视频预设仍然要求 ffmpeg/ffprobe")
    func videoPresetStillRequiresFFmpeg() {
        let video = Preset(
            name: "H.264", kind: .video, container: .mp4,
            video: VideoSettings(encoder: .libx264)
        )
        let violations = CompatibilityMatrix.validate(
            preset: video, source: MediaInfo(kind: .video),
            toolchain: snapshotWithoutFFmpeg(imageTool: .cwebp)
        )
        #expect(violations.contains { $0.message.contains("ffmpeg") })
        #expect(violations.contains { $0.message.contains("ffprobe") })
    }
}
