import Foundation
import HuaXingKit

// MARK: - Exit codes
// 0 ok, 1 args, 2 tools, 3 compatibility rejected, 4 no-match, 5 conversion-failed, 6 cancelled, 7 persistence-io

/// Top-level dispatch — parses subcommand + delegates. Returns exit code.
func dispatch(_ raw: [String]) async -> Int32 {
    guard let cmd = raw.first else { printGlobalUsage(); return 1 }
    let args = Array(raw.dropFirst())

    switch cmd {
    case "convert": return await runConvert(args)
    case "probe":   return await runProbe(args)
    case "doctor":  return await runDoctor(args)
    case "presets": return await runPresets(args)
    case "rules":   return await runRules(args)
    case "version": return runVersion(args)
    case "--help", "-h", "help", "":
        printGlobalUsage(); return 1
    default:
        FileHandle.standardError.write("Unknown command: \(cmd)\n".data(using: .utf8)!)
        printGlobalUsage(); return 1
    }
}

func printGlobalUsage() {
    let usage = """
    huaxingctl — 化形 CLI
    Usage: huaxingctl <command> [flags]

    Commands:
      convert <paths…>       Convert files
      probe   <paths…>       Show ffprobe JSON for each input
      doctor                 Verify toolchain health
      presets [list|show]    Manage presets
      rules   [list|show|run] Evaluate rules and run the matched conversions
      version                Print version

    Flags:
      --json                 Emit machine-readable output on stdout, errors on stderr
      --help, -h             Show this help
    """
    FileHandle.standardError.write(usage.data(using: .utf8)!)
}

// MARK: - version

func runVersion(_ args: [String]) -> Int32 {
    if args.contains("--json") {
        print(#"{"version":"0.1.0"}"#)
    } else {
        print("huaxingctl 0.1.0")
    }
    return 0
}

// MARK: - doctor

func runDoctor(_ args: [String]) async -> Int32 {
    let json = args.contains("--json")
    let diags = await Doctor.diagnose()

    let health = Doctor.summary(diags)

    if json {
        let list: [[String: Any]] = diags.map { d in
            [
                "severity": severityString(d.severity),
                "tool": d.tool.rawValue,
                "message": d.message,
                "installCommand": d.installCommand ?? ""
            ]
        }
        let payload: [String: Any] = [
            "diagnostics": list,
            "ok": health.ok,
            "errors": health.errors,
            "warnings": health.warnings
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        print(String(decoding: data, as: UTF8.self))
    } else {
        for d in diags {
            let icon: Character = d.severity == .ok ? "✔" : (d.severity == .warning ? "⚠" : "✖")
            let fix = d.installCommand.map { "  (fix: \($0))" } ?? ""
            FileHandle.standardError.write("\(icon) \(d.tool.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(d.message)\(fix)\n".data(using: .utf8)!)
        }
        let summary: String
        if health.errors > 0 {
            summary = "工具链异常：\(health.errors) 项错误（必需工具缺失或损坏）\n"
        } else if health.warnings > 0 {
            summary = "必需工具就绪，\(health.warnings) 项可选工具警告（不影响当前可用转换）\n"
        } else {
            summary = "All tools healthy.\n"
        }
        FileHandle.standardError.write(summary.data(using: .utf8)!)
    }

    // Only a missing/broken *required* tool is a failure. djxl/dwebp/jxlinfo/sips
    // are optional and must not turn doctor red.
    return health.ok ? 0 : 2
}

func severityString(_ s: Diagnostic.Severity) -> String {
    switch s { case .ok: return "ok"; case .warning: return "warning"; case .error: return "error" }
}

// MARK: - probe

func runProbe(_ args: [String]) async -> Int32 {
    let spec = CommandSpec(name: "probe", description: "Show ffprobe JSON",
        positionals: [Positional(name: "paths…", description: "files to probe")],
        flags: [Flag(name: "json", description: "emit as JSON", requiresValue: false)])
    let parsed: ArgParser.Parsed
    do { parsed = try ArgParser.parse(["probe"] + args, spec: spec) }
    catch { FileHandle.standardError.write("probe: \(error)\n".data(using: .utf8)!); return 1 }

    guard !parsed.positionals.isEmpty else { FileHandle.standardError.write(spec.usage().data(using: .utf8)!); return 1 }

    let ffprobe = ToolLocator.resolve(.ffprobe)
    let results = await parsed.positionals.asyncMap { path -> [String: Any] in
        do {
            let info = try await FFProbe.run(url: URL(fileURLWithPath: path), ffprobePath: ffprobe)
            return [
                "path": path,
                "kind": "\(info.kind)",
                "duration": info.duration as Any,
                "width": info.width as Any,
                "height": info.height as Any,
                "videoCodec": info.videoCodec as Any,
                "audioCodec": info.audioCodec as Any,
                "pixFmt": info.pixFmt as Any,
                "container": info.container as Any
            ].compactMapValues { $0 }
        } catch {
            return ["path": path, "error": "\(error)"]
        }
    }

    let data = try! JSONSerialization.data(withJSONObject: ["results": results], options: [.prettyPrinted])
    print(String(decoding: data, as: UTF8.self))
    return 0
}

// MARK: - convert

func runConvert(_ args: [String]) async -> Int32 {
    let spec = CommandSpec(name: "convert", description: "Convert media files",
        positionals: [Positional(name: "paths…", description: "input files (globs ok)")],
        flags: [
            Flag(name: "preset", short: "p", description: "Preset id to use", requiresValue: true),
            Flag(name: "out", short: "o", description: "Output directory", requiresValue: true),
            Flag(name: "format", short: "f", description: "Target extension", requiresValue: true),
            Flag(name: "quality", short: "q", description: "Quality (0–100)", requiresValue: true),
            Flag(name: "concurrency", short: "j", description: "Max concurrent jobs", requiresValue: true),
            Flag(name: "json", description: "Machine-readable output"),
            Flag(name: "dry-run", short: "n", description: "Show what would happen without converting"),
            Flag(name: "hevc", description: "Shortcut: HEVC videotoolbox preset"),
            Flag(name: "av1", description: "Shortcut: libsvtav1 AV1 preset"),
            Flag(name: "h264", description: "Shortcut: libx264 preset"),
            Flag(name: "m4a", description: "Shortcut: AAC m4a preset"),
            Flag(name: "jxl", description: "Shortcut: JPEG XL preset"),
            Flag(name: "webp", description: "Shortcut: WebP preset"),
        ])

    let parsed: ArgParser.Parsed
    do { parsed = try ArgParser.parse(["convert"] + args, spec: spec) }
    catch { FileHandle.standardError.write("convert: \(error)\n".data(using: .utf8)!); return 1 }

    guard !parsed.positionals.isEmpty else {
        FileHandle.standardError.write(spec.usage().data(using: .utf8)!)
        return 1
    }

    let jsonMode = parsed.boolFlags.contains("json")
    let dryRun = parsed.boolFlags.contains("dry-run")

    // Resolve paths (glob expansion for shell users who didn't expand)
    var inputs: [URL] = []
    let fm = FileManager.default
    for p in parsed.positionals {
        let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        let attrs = try? fm.attributesOfItem(atPath: u.path)
        let isDir = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        if u.hasDirectoryPath || isDir {
            inputs.append(contentsOf: collectFiles(from: u, fm: fm))
        } else if fm.fileExists(atPath: u.path) {
            inputs.append(u)
        }
    }
    if inputs.isEmpty {
        FileHandle.standardError.write("convert: no input files found\n".data(using: .utf8)!)
        return 1
    }

    // Build preset
    var preset: Preset
    if let presetID = parsed.value("preset") {
        do {
            let store = PresetStore()
            guard let found = try store.load().first(where: { $0.id == presetID }) else {
                FileHandle.standardError.write("convert: preset '\(presetID)' not found\n".data(using: .utf8)!)
                return 4
            }
            preset = found
        } catch {
            FileHandle.standardError.write("convert: preset store error \(error)\n".data(using: .utf8)!)
            return 7
        }
    } else if parsed.boolFlags.contains("jxl") || parsed.boolFlags.contains("webp") {
        let target: ImageTarget = parsed.boolFlags.contains("jxl") ? .jxl : .webp
        let ext: String = target == .jxl ? "jxl" : "webp"
        preset = Preset(name: "CLI \(ext)", kind: .image, container: .mp4,
            image: ImageSettings(target: target))
    } else if parsed.boolFlags.contains("hevc") {
        preset = Preset(name: "CLI HEVC", kind: .video, container: .mp4,
            video: VideoSettings(encoder: .hevc_videotoolbox, bitrate: "3M", scaleVt: true),
            audio: AudioSettings(encoder: .aac, bitrate: "128k"))
    } else if parsed.boolFlags.contains("av1") {
        preset = Preset(name: "CLI AV1", kind: .video, container: .mp4,
            video: VideoSettings(encoder: .libsvtav1, crf: 30, preset: "8"),
            audio: AudioSettings(encoder: .aac, bitrate: "128k"))
    } else if parsed.boolFlags.contains("m4a") {
        preset = Preset(name: "CLI m4a", kind: .audio, container: .m4a,
            audio: AudioSettings(encoder: .aac, bitrate: "192k"))
    } else {
        preset = Preset(name: "CLI H.264", kind: .video, container: .mp4,
            video: VideoSettings(encoder: .libx264, crf: 23, preset: "medium"),
            audio: AudioSettings(encoder: .aac, bitrate: "128k"))
    }

    // --quality: image presets only. 0-100 for cjxl/cwebp; ImageIO targets also
    // accept 0-100 and are normalized to 0-1 inside ImagePipeline.
    if let qualityText = parsed.value("quality") {
        guard let quality = Double(qualityText), (0...100).contains(quality) else {
            FileHandle.standardError.write("convert: --quality must be between 0 and 100\n".data(using: .utf8)!)
            return 1
        }
        if preset.image != nil {
            preset.image?.quality = quality
            // A lossy quality request must disable lossless, otherwise JXL/WebP
            // ignore the quality value entirely.
            preset.image?.lossless = false
        } else {
            FileHandle.standardError.write("convert: --quality only applies to image presets\n".data(using: .utf8)!)
        }
    }

    // The output extension must match the container/target; otherwise ffmpeg
    // happily writes MP4 bytes into a .webm filename.
    let naturalExtension: String = {
        if let img = preset.image { return targetExtension(img.target) }
        return containerExtension(preset.container)
    }()
    if let requested = parsed.value("format")?.lowercased(),
       requested != naturalExtension {
        FileHandle.standardError.write(
            "convert: --format \(requested) does not match preset output .\(naturalExtension)\n".data(using: .utf8)!
        )
        return 1
    }

    // Output dir — an explicit --out wins; otherwise honor the preset's own
    // outputDirectory instead of silently forcing ~/huaxing-out.
    let outDir: URL = {
        if let p = parsed.value("out") {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        if parsed.value("preset") != nil, !preset.outputDirectory.isEmpty {
            return URL(
                fileURLWithPath: (preset.outputDirectory as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("huaxing-out")
    }()
    try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

    // Image conversions go through ImageIO / cjxl / cwebp — ffmpeg is NOT
    // required for them. ffprobe is still used for validation + naming tokens.
    guard let ffprobePath = ToolLocator.resolve(.ffprobe) else {
        FileHandle.standardError.write("ffprobe not found — run 'huaxingctl doctor'\n".data(using: .utf8)!)
        return 2
    }
    let ffmpegPath = ToolLocator.resolve(.ffmpeg)
    if preset.image == nil && ffmpegPath == nil {
        FileHandle.standardError.write("ffmpeg not found — required for video/audio conversion\n".data(using: .utf8)!)
        return 2
    }

    let toolchain = await Toolchain().snapshot()

    let maxConcurrent: Int = {
        guard let raw = parsed.value("concurrency") else { return 1 }
        guard let n = Int(raw), n > 0 else { return 1 }
        return n
    }()

    // Freeze the preset — the outer var was mutated by --quality and must not
    // be captured by concurrently-executing code.
    let resolvedPreset = preset

    // Pre-allocate output paths serially. Probe once here so the naming
    // template sees {width}/{height}/{duration}/{codec}, then reserve every
    // path so two concurrent jobs can never write to the same file.
    var planned: [PlannedJob] = []
    var reserved = Set<String>()
    for input in inputs {
        let mediaInfo = try? await FFProbe.run(url: input, ffprobePath: ffprobePath)
        let ctx = NamingContext(
            name: input.deletingPathExtension().lastPathComponent,
            ext: naturalExtension,
            width: mediaInfo?.width,
            height: mediaInfo?.height,
            duration: mediaInfo?.duration,
            codec: mediaInfo?.videoCodec ?? mediaInfo?.audioCodec ?? "",
            preset: resolvedPreset.id
        )
        let rendered = NamingTemplate(resolvedPreset.naming).render(ctx)
        let baseName = rendered.hasSuffix(".\(naturalExtension)")
            ? rendered : "\(rendered).\(naturalExtension)"
        var candidate = outDir.appendingPathComponent(baseName)
        let stem = candidate.deletingPathExtension().lastPathComponent
        var index = 1
        while fm.fileExists(atPath: candidate.path)
            || reserved.contains(candidate.standardizedFileURL.path) {
            candidate = outDir.appendingPathComponent("\(stem)-\(index).\(naturalExtension)")
            index += 1
        }
        reserved.insert(candidate.standardizedFileURL.path)
        planned.append(PlannedJob(input: input, output: candidate, mediaInfo: mediaInfo))
    }

    // Each input is processed in isolation and returns a Sendable outcome, so
    // batches can run concurrently without sharing mutable state.
    let convertOne: @Sendable (PlannedJob) async -> ConvertOutcome = { job in
        await performConversion(
            input: job.input,
            output: job.output,
            preset: resolvedPreset,
            mediaInfo: job.mediaInfo,
            toolchain: toolchain,
            ffmpegPath: ffmpegPath,
            keepMetadata: resolvedPreset.keepMetadata,
            dryRun: dryRun
        )
    }

    // Bounded concurrency: launch at most `maxConcurrent` jobs, preserve the
    // original input order in the report.
    var outcomes: [ConvertOutcome] = []
    outcomes.reserveCapacity(planned.count)
    var cursor = 0
    while cursor < planned.count {
        let end = min(cursor + maxConcurrent, planned.count)
        let batch = Array(planned[cursor..<end])
        let batchOutcomes = await withTaskGroup(of: (Int, ConvertOutcome).self) { group in
            for (offset, item) in batch.enumerated() {
                group.addTask {
                    (offset, await convertOne(item))
                }
            }
            var pairs: [(Int, ConvertOutcome)] = []
            for await pair in group { pairs.append(pair) }
            return pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
        outcomes.append(contentsOf: batchOutcomes)
        cursor = end
    }

    var results: [[String: Any]] = []
    var exitCode: Int32 = 0

    for outcome in outcomes {
        if outcome.exitCode != 0 { exitCode = outcome.exitCode }

        if let error = outcome.error {
            if jsonMode {
                results.append(["input": outcome.inputPath, "error": error])
            } else {
                FileHandle.standardError.write("✖ \(outcome.inputName): \(error)\n".data(using: .utf8)!)
            }
            continue
        }

        if outcome.dryRun {
            FileHandle.standardError.write("[dry-run] \(outcome.inputName) → \(outcome.outputName)\n".data(using: .utf8)!)
            results.append(["input": outcome.inputPath, "output": outcome.outputPath, "dryRun": true])
            continue
        }

        if jsonMode {
            var dict: [String: Any] = [
                "input": outcome.inputPath,
                "output": outcome.outputPath,
                "seconds": outcome.seconds ?? 0,
                "metadataLost": outcome.metadataLost ?? false
            ]
            if let bytes = outcome.bytes { dict["bytes"] = bytes }
            results.append(dict)
        } else {
            FileHandle.standardError.write("✔ \(outcome.label)  \(outcome.outputName)\n".data(using: .utf8)!)
        }
    }

    if jsonMode {
        let data = try! JSONSerialization.data(withJSONObject: ["ok": exitCode == 0, "exitCode": exitCode, "results": results], options: [.prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }
    return exitCode
}

/// A single pre-resolved conversion job. `mediaInfo` is probed once up front
/// and shared by naming, compatibility validation and the pipeline itself.
struct PlannedJob: Sendable {
    var input: URL
    var output: URL
    var mediaInfo: MediaInfo?
}

struct ConvertOutcome: Sendable {
    var inputPath: String
    var inputName: String
    var outputPath: String
    var outputName: String
    var label: String
    var error: String?
    var seconds: Double?
    var bytes: Int64?
    var metadataLost: Bool?
    var dryRun: Bool = false
    var exitCode: Int32
    /// converted / dryRun / failed / skipped / noMatch — used by `rules run`.
    var status: String = "converted"
    var ruleName: String?
    var presetID: String?

    static func failed(
        input: URL, output: URL, message: String, code: Int32
    ) -> ConvertOutcome {
        ConvertOutcome(
            inputPath: input.path,
            inputName: input.lastPathComponent,
            outputPath: output.path,
            outputName: output.lastPathComponent,
            label: "",
            error: message,
            exitCode: code,
            status: "failed"
        )
    }
}

/// Shared validation + pipeline dispatch used by both `convert` and `rules run`.
/// `ffmpegPath` may be nil for image presets — ImageIO/cjxl/cwebp never use it.
func performConversion(
    input: URL,
    output: URL,
    preset: Preset,
    mediaInfo: MediaInfo?,
    toolchain: ToolchainSnapshot,
    ffmpegPath: String?,
    keepMetadata: Bool,
    dryRun: Bool
) async -> ConvertOutcome {
    func fail(_ message: String, code: Int32) -> ConvertOutcome {
        .failed(input: input, output: output, message: message, code: code)
    }

    if let info = mediaInfo, let mismatch = presetKindMismatch(preset.kind, info.kind) {
        return fail(mismatch, code: 3)
    }

    // Container/codec/tool compatibility — fail before spawning any process.
    let violations = CompatibilityMatrix.validate(
        preset: preset,
        source: mediaInfo ?? MediaInfo(kind: preset.kind),
        toolchain: toolchain
    )
    if !violations.isEmpty {
        return fail(violations.map(\.message).joined(separator: "；"), code: 3)
    }

    if dryRun {
        return ConvertOutcome(
            inputPath: input.path, inputName: input.lastPathComponent,
            outputPath: output.path, outputName: output.lastPathComponent,
            label: "", dryRun: true, exitCode: 0, status: "dryRun"
        )
    }

    let label = preset.image != nil ? "Image" : (preset.kind == .audio ? "Audio" : "Video")

    do {
        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let img = preset.image {
            let pipeline = ImagePipeline(toolchain: toolchain)
            let result = try await pipeline.run(
                input: input, output: output,
                settings: img, keepMetadata: keepMetadata
            )
            return ConvertOutcome(
                inputPath: input.path, inputName: input.lastPathComponent,
                outputPath: output.path, outputName: output.lastPathComponent,
                label: label,
                seconds: result.wallClockSeconds,
                bytes: result.outputBytes,
                metadataLost: result.metadataLost,
                exitCode: 0
            )
        }

        guard let ffmpegPath else {
            return fail("ffmpeg 不可用，无法执行视频/音频转换", code: 2)
        }

        // Follow the preset, not the source: an audio preset applied to a
        // video file must extract audio, not stream-copy the video.
        let result = preset.kind == .audio
            ? try await AudioPipeline(ffmpegPath: ffmpegPath).run(
                input: input, output: output, preset: preset
            )
            : try await VideoPipeline(ffmpegPath: ffmpegPath).run(
                input: input, output: output, preset: preset
            )
        return ConvertOutcome(
            inputPath: input.path, inputName: input.lastPathComponent,
            outputPath: output.path, outputName: output.lastPathComponent,
            label: label,
            seconds: result.wallClockSeconds,
            bytes: result.outputBytes,
            exitCode: 0
        )
    } catch {
        return fail(error.localizedDescription, code: 5)
    }
}

func presetKindMismatch(_ preset: MediaInfo.Kind, _ source: MediaInfo.Kind) -> String? {
    switch preset {
    case .video:
        return source == .video ? nil : "视频预设不能用于\(source)文件"
    case .image:
        return source == .image ? nil : "图片预设不能用于\(source)文件"
    case .audio:
        return source == .image ? "音频预设不能用于图片文件" : nil
    }
}

func targetExtension(_ t: ImageTarget) -> String {
    switch t {
    case .jxl: return "jxl"
    case .webp: return "webp"
    case .jpeg: return "jpg"
    case .png: return "png"
    case .tiff: return "tiff"
    case .heic, .heics: return "heic"
    case .avif: return "avif"
    case .gif: return "gif"
    case .bmp: return "bmp"
    case .ico: return "ico"
    case .icns: return "icns"
    case .exr: return "exr"
    case .psd: return "psd"
    case .jp2: return "jp2"
    }
}

func containerExtension(_ c: Container) -> String {
    switch c {
    case .mp4: return "mp4"
    case .mkv: return "mkv"
    case .webm: return "webm"
    case .mov: return "mov"
    case .m4a, .ipod: return "m4a"
    case .mp3: return "mp3"
    case .wav: return "wav"
    case .flac: return "flac"
    case .ogg: return "ogg"
    }
}

// MARK: - presets

func runPresets(_ args: [String]) async -> Int32 {
    let subcmd = args.first ?? "list"
    let rest = Array(args.dropFirst())

    switch subcmd {
    case "list":
        do {
            let store = PresetStore()
            let list = try store.load()
            let data = try! JSONEncoder().encode(list)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write("presets list: \(error)\n".data(using: .utf8)!); return 7
        }
    case "show":
        let id = rest.first ?? ""
        do {
            let store = PresetStore()
            guard let p = try store.load().first(where: { $0.id == id }) else {
                FileHandle.standardError.write("presets show: id '\(id)' not found\n".data(using: .utf8)!); return 4
            }
            let data = try! JSONEncoder().encode(p)
            print(String(decoding: data, as: UTF8.self))
        } catch { FileHandle.standardError.write("presets show: \(error)\n".data(using: .utf8)!); return 7 }
    default:
        FileHandle.standardError.write("Usage: huaxingctl presets [list|show <id>]\n".data(using: .utf8)!); return 1
    }
    return 0
}

// MARK: - rules

func runRules(_ args: [String]) async -> Int32 {
    let subcmd = args.first ?? "list"
    let rest = Array(args.dropFirst())

    switch subcmd {
    case "list":
        do {
            let store = RuleStore()
            let list = try store.load()
            let data = try! JSONEncoder().encode(list)
            print(String(decoding: data, as: UTF8.self))
        } catch { FileHandle.standardError.write("rules list: \(error)\n".data(using: .utf8)!); return 7 }
    case "show":
        let id = rest.first ?? ""
        do {
            let store = RuleStore()
            guard let r = try store.load().first(where: { $0.id == id }) else {
                FileHandle.standardError.write("rules show: id '\(id)' not found\n".data(using: .utf8)!); return 4
            }
            let data = try! JSONEncoder().encode(r)
            print(String(decoding: data, as: UTF8.self))
        } catch { FileHandle.standardError.write("rules show: \(error)\n".data(using: .utf8)!); return 7 }
    case "run":
        return await runRulesRun(rest)
    default:
        FileHandle.standardError.write("Usage: huaxingctl rules [list|show <id>|run <paths…> [--rule <id>] [--dry-run] [--json]]\n".data(using: .utf8)!); return 1
    }
    return 0
}

/// `rules run` really converts: evaluate → build a plan (preset + output
/// directory + naming + collision policy) → run the pipeline → post-process.
/// `--dry-run` stops after the plan and `--rule` is optional (all enabled
/// rules are evaluated by priority when omitted).
func runRulesRun(_ args: [String]) async -> Int32 {
    let spec = CommandSpec(name: "run", description: "Match rules and convert inputs",
        positionals: [Positional(name: "paths…", description: "files or directories")],
        flags: [
            Flag(name: "rule", short: "r", description: "Only evaluate this rule id (default: all enabled rules)", requiresValue: true),
            Flag(name: "dry-run", short: "n", description: "Show the plan without converting"),
            Flag(name: "json", description: "Machine-readable")
        ])
    let parsed: ArgParser.Parsed
    do { parsed = try ArgParser.parse(["run"] + args, spec: spec) }
    catch { FileHandle.standardError.write("rules run: \(error)\n".data(using: .utf8)!); return 1 }

    guard !parsed.positionals.isEmpty else {
        FileHandle.standardError.write(spec.usage().data(using: .utf8)!)
        return 1
    }

    let jsonMode = parsed.boolFlags.contains("json")
    let dryRun = parsed.boolFlags.contains("dry-run")
    let fm = FileManager.default

    let active: [Rule]
    let presets: [Preset]
    do {
        let rules = try RuleStore().load()
        if let ruleID = parsed.value("rule") {
            active = rules.filter { $0.id == ruleID }
            guard !active.isEmpty else {
                FileHandle.standardError.write("rules run: rule '\(ruleID)' does not exist\n".data(using: .utf8)!)
                return 4
            }
        } else {
            active = rules.filter { $0.enabled }
            guard !active.isEmpty else {
                FileHandle.standardError.write("rules run: no enabled rules\n".data(using: .utf8)!)
                return 4
            }
        }
        presets = try PresetStore().load()
    } catch {
        FileHandle.standardError.write("rules run: \(error)\n".data(using: .utf8)!)
        return 7
    }

    // Expand directories the same way `convert` does.
    var inputs: [URL] = []
    for path in parsed.positionals {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            inputs.append(contentsOf: collectFiles(from: url, fm: fm))
        } else {
            inputs.append(url)
        }
    }
    guard !inputs.isEmpty else {
        FileHandle.standardError.write("rules run: no input files found\n".data(using: .utf8)!)
        return 1
    }

    // ffprobe is enough for image rules; ffmpeg is only needed for video/audio,
    // and is resolved lazily so a missing ffmpeg can't block an image rule.
    guard let ffprobePath = ToolLocator.resolve(.ffprobe) else {
        FileHandle.standardError.write("rules run: ffprobe not found — run 'huaxingctl doctor'\n".data(using: .utf8)!)
        return 2
    }
    let ffmpegPath = ToolLocator.resolve(.ffmpeg)
    let toolchain = await Toolchain().snapshot()

    var results: [[String: Any]] = []
    var occupied = Set<String>()
    var matched = 0, converted = 0, skipped = 0, failed = 0

    for url in inputs {
        let mediaInfo = try? await FFProbe.run(url: url, ffprobePath: ffprobePath)
        let ruleInput = RuleInput(
            url: url,
            utType: mediaInfo?.utType,
            byteSize: try? fmSize(url),
            sourceDirectory: url.deletingLastPathComponent().path,
            mediaInfo: mediaInfo
        )
        let decision = await RuleEngine.evaluate(ruleInput, rules: active)

        guard case .matched(let rule) = decision else {
            results.append(["input": url.path, "status": "noMatch"])
            if !jsonMode { writeErr("— \(url.lastPathComponent) 未命中规则") }
            continue
        }
        matched += 1

        guard let preset = presets.first(where: { $0.id == rule.action.presetID }) else {
            failed += 1
            let message = "规则「\(rule.name)」引用的预设 \(rule.action.presetID) 不存在"
            results.append([
                "input": url.path, "status": "failed", "matched": true,
                "rule": rule.name, "error": message
            ])
            if !jsonMode { writeErr("✖ \(url.lastPathComponent): \(message)") }
            continue
        }

        let plan: RuleExecutionPlan
        do {
            plan = try RuleExecutor.makePlan(
                input: url, mediaInfo: mediaInfo, rule: rule,
                preset: preset, occupied: occupied
            )
        } catch RuleExecutionError.outputAlreadyExists(let path) {
            // collisionPolicy == .skip
            skipped += 1
            results.append([
                "input": url.path, "output": path, "status": "skipped",
                "matched": true, "rule": rule.name, "preset": preset.id,
                "collisionPolicy": "skip"
            ])
            if !jsonMode { writeErr("⊘ \(url.lastPathComponent) 已跳过（冲突策略：跳过）") }
            continue
        } catch {
            failed += 1
            results.append([
                "input": url.path, "status": "failed", "matched": true,
                "rule": rule.name, "error": error.localizedDescription
            ])
            if !jsonMode { writeErr("✖ \(url.lastPathComponent): \(error.localizedDescription)") }
            continue
        }
        occupied.insert(plan.outputURL.standardizedFileURL.path)

        if dryRun {
            results.append([
                "input": url.path, "output": plan.outputURL.path,
                "status": "dryRun", "matched": true,
                "rule": rule.name, "preset": preset.id,
                "collisionPolicy": "\(rule.action.collisionPolicy)",
                "postProcessing": plan.postProcessing.map { "\($0)" }
            ])
            if !jsonMode { writeErr("[dry-run] \(url.lastPathComponent) → \(plan.outputURL.path)") }
            continue
        }

        do {
            try fm.createDirectory(
                at: plan.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            failed += 1
            results.append([
                "input": url.path, "output": plan.outputURL.path,
                "status": "failed", "matched": true,
                "rule": rule.name, "error": error.localizedDescription
            ])
            if !jsonMode { writeErr("✖ \(url.lastPathComponent): \(error.localizedDescription)") }
            continue
        }

        var outcome = await performConversion(
            input: url, output: plan.outputURL, preset: preset,
            mediaInfo: mediaInfo, toolchain: toolchain,
            ffmpegPath: ffmpegPath,
            keepMetadata: plan.keepMetadata,
            dryRun: false
        )
        outcome.ruleName = rule.name
        outcome.presetID = preset.id

        if outcome.error != nil {
            failed += 1
        } else {
            converted += 1
            // revealInFinder / openResult / trashSource
            await RuleExecutor.performPostProcessing(
                plan.postProcessing, output: plan.outputURL, source: url
            )
        }
        results.append(outcomeFields(outcome))
        if !jsonMode {
            if let error = outcome.error {
                writeErr("✖ \(url.lastPathComponent): \(error)")
            } else {
                writeErr("✔ \(url.lastPathComponent) → \(plan.outputURL.lastPathComponent)（规则：\(rule.name)）")
            }
        }
    }

    // 4 = no match / missing config, 5 = at least one conversion failed.
    let exitCode: Int32 = failed > 0 ? 5 : (matched == 0 ? 4 : 0)
    let payload: [String: Any] = [
        "ok": exitCode == 0,
        "exitCode": exitCode,
        "matched": matched,
        "converted": converted,
        "skipped": skipped,
        "failed": failed,
        "total": inputs.count,
        "results": results
    ]
    if jsonMode {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    } else {
        writeErr("Matched \(matched) of \(inputs.count) · converted \(converted) · skipped \(skipped) · failed \(failed)")
        print("\(converted) converted")
    }
    return exitCode
}

func writeErr(_ line: String) {
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
}

func outcomeFields(_ o: ConvertOutcome) -> [String: Any] {
    var dict: [String: Any] = [
        "input": o.inputPath,
        "output": o.outputPath,
        "matched": true,
        "status": o.error == nil ? (o.dryRun ? "dryRun" : "converted") : "failed",
        "exitCode": o.exitCode
    ]
    if let v = o.ruleName { dict["rule"] = v }
    if let v = o.presetID { dict["preset"] = v }
    if let v = o.seconds { dict["seconds"] = v }
    if let v = o.bytes { dict["bytes"] = v }
    if let v = o.metadataLost { dict["metadataLost"] = v }
    if let v = o.error { dict["error"] = v }
    return dict
}

func fmSize(_ url: URL) throws -> Int64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.size] as? NSNumber)?.int64Value ?? 0
}

/// Sync file enumeration — called from convert async function but runs
/// on the current caller's thread (we don't await a Task so it's fine).
func collectFiles(from root: URL, fm: FileManager) -> [URL] {
    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }
    var urls: [URL] = []
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
        guard values?.isRegularFile == true, values?.isHidden != true else { continue }
        urls.append(url)
    }
    return urls
}
