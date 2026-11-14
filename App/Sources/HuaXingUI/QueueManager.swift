import Foundation
import Combine
import HuaXingKit

// MARK: - QueueManager

/// 顶层转换调度器。管理 pending/running/finished 任务队列，
/// 控制并发数，驱动 VideoPipeline / AudioPipeline / ImagePipeline。
///
/// 所有状态通过 @Published 暴露，SwiftUI 视图直接订阅 `jobs` 数组。
/// 内部逻辑全部运行在 @MainActor 上（ObservableObject 约定），
/// 管线调用通过 async/await 挂起 MainActor 线程（不阻塞）。
@MainActor
public final class QueueManager: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var jobs: [JobModel] = []
    @Published public var maxConcurrent: Int = 2 {
        didSet {
            if maxConcurrent < 1 { maxConcurrent = 1 }
            Task { @MainActor in await self.schedule() }
        }
    }
    @Published public private(set) var isRunning: Bool = false

    // MARK: - Dependencies

    /// 从 AppModel 注入，获取 ffmpeg/cjxl/cwebp 路径。
    /// 用闭包避免循环引用（AppModel 持有 QueueManager，QueueManager 反查 AppModel）。
    public var pathProvider: () async -> ToolchainSnapshot?

    /// 用弱引用避免循环 —— QueueManager 不需要强持有 AppModel。
    public weak var appModel: AppModel?

    // MARK: - Private state

    private var runningIDs: Set<UUID> = []
    private var scheduleTask: Task<Void, Never>?
    private var jobObservers: [UUID: AnyCancellable] = [:]

    // MARK: - Init

    public init(
        appModel: AppModel? = nil,
        pathProvider: @escaping () async -> ToolchainSnapshot? = { nil }
    ) {
        self.appModel = appModel
        self.pathProvider = pathProvider
    }

    // MARK: - Submit

    /// 提交一个转换任务。立即返回任务 ID，任务会在合适的时机启动。
    /// 入队前会 ffprobe 一次，让命名模板中的 {width}/{height}/{duration} 生效。
    @discardableResult
    public func submit(input: URL, outputDirectory: URL, preset: Preset) async -> UUID {
        let mediaInfo = await probeInfo(input)
        let outputURL = uniqueOutput(
            Self.resolveOutput(
                input: input,
                outputDirectory: outputDirectory,
                preset: preset,
                mediaInfo: mediaInfo
            )
        )

        let job = JobModel(inputURL: input, outputURL: outputURL, preset: preset)
        jobs.append(job)
        observe(job)
        await schedule()
        return job.id
    }

    /// 根据规则自动选择预设 / 输出目录 / 命名 / 后处理。
    ///
    /// - Returns: 任务 ID；当冲突策略为 `.skip` 且输出已存在时返回 nil。
    @discardableResult
    public func submit(
        input: URL,
        fallbackPreset: Preset?,
        fallbackDirectory: URL?,
        rules: [Rule],
        presets: [Preset]
    ) async throws -> UUID? {
        let mediaInfo = await probeInfo(input)

        if !rules.isEmpty {
            let byteSize: Int64? = {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: input.path),
                      let size = attrs[.size] as? NSNumber else { return nil }
                return size.int64Value
            }()
            let ruleInput = RuleInput(
                url: input,
                utType: mediaInfo?.utType,
                byteSize: byteSize,
                sourceDirectory: input.deletingLastPathComponent().path,
                mediaInfo: mediaInfo
            )
            let decision = await RuleEngine.evaluate(ruleInput, rules: rules)

            if case .matched(let rule) = decision {
                guard let preset = presets.first(where: { $0.id == rule.action.presetID }) else {
                    throw QueueError.invalidPreset(
                        "规则「\(rule.name)」引用的预设 \(rule.action.presetID) 不存在"
                    )
                }

                do {
                    let plan = try RuleExecutor.makePlan(
                        input: input,
                        mediaInfo: mediaInfo,
                        rule: rule,
                        preset: preset,
                        occupied: Set(jobs.map { $0.outputURL.standardizedFileURL.path })
                    )
                    try FileManager.default.createDirectory(
                        at: plan.outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let job = JobModel(
                        inputURL: input,
                        outputURL: plan.outputURL,
                        preset: preset,
                        ruleName: rule.name,
                        postProcessing: plan.postProcessing,
                        keepMetadata: plan.keepMetadata
                    )
                    jobs.append(job)
                    observe(job)
                    await schedule()
                    return job.id
                } catch RuleExecutionError.outputAlreadyExists {
                    return nil
                }
            }
        }

        // Fallback: manual preset + manual/global directory.
        guard let preset = fallbackPreset else {
            throw QueueError.invalidPreset("没有可用预设，且没有匹配的规则")
        }
        let directory = fallbackDirectory ?? URL(
            fileURLWithPath: (preset.outputDirectory as NSString).expandingTildeInPath,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputURL = uniqueOutput(
            Self.resolveOutput(
                input: input,
                outputDirectory: directory,
                preset: preset,
                mediaInfo: mediaInfo
            )
        )
        let job = JobModel(inputURL: input, outputURL: outputURL, preset: preset)
        jobs.append(job)
        observe(job)
        await schedule()
        return job.id
    }

    /// 便捷重载 —— 直接传 outputURL。
    @discardableResult
    public func submit(input: URL, outputURL: URL, preset: Preset) async -> UUID {
        let job = JobModel(inputURL: input, outputURL: outputURL, preset: preset)
        jobs.append(job)
        observe(job)
        await schedule()
        return job.id
    }

    /// JobModel 是引用类型；Table 行不会自动订阅它的 @Published 变化。
    /// 这里把每个 job 的 objectWillChange 转发给 QueueManager，确保状态/进度刷新。
    private func observe(_ job: JobModel) {
        let cancellable = job.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        jobObservers[job.id] = cancellable
    }

    // MARK: - Control

    public func cancel(jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        job.markCancelled()
    }

    public func cancelAll() {
        for job in jobs where job.isActive {
            job.markCancelled()
        }
    }

    /// 清除已完成/失败/取消的任务。
    public func clearTerminal() {
        let removed = jobs.filter { $0.isTerminal }.map(\.id)
        jobs.removeAll { $0.isTerminal }
        for id in removed { jobObservers.removeValue(forKey: id) }
    }

    // MARK: - Scheduling

    private func schedule() async {
        isRunning = !jobs.allSatisfy { $0.isTerminal }

        while runningIDs.count < maxConcurrent {
            guard let next = jobs.first(where: { $0.status == .pending }) else { break }
            runningIDs.insert(next.id)
            // 不 await —— fire-and-forget，让多个管线并发
            Task { [weak self] in
                await self?.runJob(next)
            }
        }
    }

    private func runJob(_ job: JobModel) async {
        defer {
            runningIDs.remove(job.id)
            // 收尾后尝试拉起下一个 pending
            Task { @MainActor [weak self] in
                await self?.schedule()
            }
        }

        guard job.status != .cancelled else { return }
        job.markRunning()

        // 解析工具链
        guard let snap = await pathProvider() else {
            job.markFailed(QueueError.toolchainUnavailable)
            return
        }

        // Probe once: used for validation, progress fraction and type checks.
        let ffprobePath: String? = {
            if case .success(let r) = snap.tools[.ffprobe] { return r.path }
            return nil
        }()
        let sourceInfo = try? await FFProbe.run(url: job.inputURL, ffprobePath: ffprobePath)

        if let info = sourceInfo {
            if job.preset.kind == .video && info.kind != .video {
                job.markFailed(QueueError.invalidPreset("视频预设只能用于视频文件"))
                return
            }
            if job.preset.kind == .image && info.kind != .image {
                job.markFailed(QueueError.invalidPreset("图片预设只能用于图片文件"))
                return
            }
        }

        let violations = CompatibilityMatrix.validate(
            preset: job.preset,
            source: sourceInfo ?? MediaInfo(kind: job.preset.kind),
            toolchain: snap
        )
        if !violations.isEmpty {
            job.markFailed(QueueError.incompatible(violations.map(\.message)))
            return
        }

        do {
            switch job.preset.kind {
            case .video:
                try await runVideo(job: job, snapshot: snap, duration: sourceInfo?.duration)
            case .audio:
                try await runAudio(job: job, snapshot: snap, duration: sourceInfo?.duration)
            case .image:
                try await runImage(job: job, snapshot: snap)
            }
        } catch is CancellationError {
            job.markCancelled()
        } catch {
            if job.status != .cancelled {
                job.markFailed(error)
            }
        }

        if job.status == .finished {
            await RuleExecutor.performPostProcessing(
                job.postProcessing,
                output: job.outputURL,
                source: job.inputURL
            )
        }
    }

    // MARK: - Probing

    /// ffprobe once so progress, validation and naming tokens all share it.
    private func probeInfo(_ url: URL) async -> MediaInfo? {
        guard let snapshot = await pathProvider() else { return nil }
        guard case .success(let ffprobe) = snapshot.tools[.ffprobe] else { return nil }
        return try? await FFProbe.run(url: url, ffprobePath: ffprobe.path)
    }

    // MARK: - Pipeline runners

    private func runVideo(
        job: JobModel,
        snapshot: ToolchainSnapshot,
        duration: Double?
    ) async throws {
        guard case .success(let ffmpeg) = snapshot.tools[.ffmpeg] else {
            throw QueueError.toolMissing("ffmpeg")
        }
        let pipeline = VideoPipeline(ffmpegPath: ffmpeg.path)

        let result = try await pipeline.run(
            input: job.inputURL,
            output: job.outputURL,
            preset: job.preset,
            progress: { [weak self] prog in
                Task { @MainActor in
                    self?.updateProgress(for: job, progress: prog, duration: duration)
                }
            },
            onStart: { handle in
                Task { @MainActor in job.cancellationHandle = handle }
            }
        )
        guard job.status != .cancelled else { return }
        job.markFinished(result: result)
    }

    private func runAudio(
        job: JobModel,
        snapshot: ToolchainSnapshot,
        duration: Double?
    ) async throws {
        guard case .success(let ffmpeg) = snapshot.tools[.ffmpeg] else {
            throw QueueError.toolMissing("ffmpeg")
        }
        let pipeline = AudioPipeline(ffmpegPath: ffmpeg.path)
        let result = try await pipeline.run(
            input: job.inputURL,
            output: job.outputURL,
            preset: job.preset,
            progress: { [weak self] prog in
                Task { @MainActor in
                    self?.updateProgress(for: job, progress: prog, duration: duration)
                }
            },
            onStart: { handle in
                Task { @MainActor in job.cancellationHandle = handle }
            }
        )
        guard job.status != .cancelled else { return }
        job.markFinished(result: result)
    }

    private func runImage(job: JobModel, snapshot: ToolchainSnapshot) async throws {
        let pipeline = ImagePipeline(toolchain: snapshot)
        guard let settings = job.preset.image else {
            throw QueueError.invalidPreset("图片预设缺少图片设置")
        }
        let result = try await pipeline.run(
            input: job.inputURL,
            output: job.outputURL,
            settings: settings,
            keepMetadata: job.keepMetadata
        )
        guard job.status != .cancelled else { return }
        job.markImageFinished(result: result)
    }

    private func updateProgress(for job: JobModel, progress: FFmpegProgress, duration: Double?) {
        guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { return }

        if let duration, duration > 0, let micros = progress.outTimeMicroseconds {
            let fraction = min(max(Double(micros) / 1_000_000 / duration, 0), 1)
            jobs[idx].updateProgress(fraction, speed: progress.speed)
        } else if progress.done {
            jobs[idx].updateProgress(1, speed: progress.speed)
        } else if let speed = progress.speed {
            jobs[idx].updateProgress(jobs[idx].progressFraction, speed: speed)
        }
    }

    // MARK: - Output path resolution

    /// 根据 preset.naming 模板生成输出文件名。
    /// 避免覆盖已有文件或同一批次中的同名任务：追加 -1、-2…
    private func uniqueOutput(_ url: URL) -> URL {
        let fm = FileManager.default
        let planned = Set(jobs.map { $0.outputURL.standardizedFileURL.path })
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var candidate = url
        var index = 1
        while fm.fileExists(atPath: candidate.path)
            || planned.contains(candidate.standardizedFileURL.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(index).\(ext)")
            index += 1
        }
        return candidate
    }

    static func resolveOutput(
        input: URL,
        outputDirectory: URL,
        preset: Preset,
        mediaInfo: MediaInfo? = nil
    ) -> URL {
        let ext = preset.outputExtension
        let stem = input.deletingPathExtension().lastPathComponent
        let codec = preset.video?.encoder.rawValue
            ?? preset.audio?.encoder.rawValue
            ?? preset.image?.target.rawValue
            ?? ""

        let ctx = NamingContext(
            name: stem,
            ext: ext,
            width: mediaInfo?.width,
            height: mediaInfo?.height,
            duration: mediaInfo?.duration,
            codec: codec,
            preset: preset.id
        )
        let name = NamingTemplate(preset.naming).render(ctx)
        // Avoid `foo.mp4.mp4` when the template already contains {ext}.
        let stemOrName = name.hasSuffix(".\(ext)") ? name : "\(name).\(ext)"
        return outputDirectory.appendingPathComponent(stemOrName)
    }
}

// MARK: - Errors

public enum QueueError: Error, Sendable, LocalizedError {
    case toolchainUnavailable
    case toolMissing(String)
    case invalidPreset(String)
    case incompatible([String])

    public var errorDescription: String? {
        switch self {
        case .toolchainUnavailable:
            return "工具链未就绪，请先运行诊断"
        case .toolMissing(let name):
            return "缺少必需工具：\(name)"
        case .invalidPreset(let msg):
            return "预设配置无效：\(msg)"
        case .incompatible(let messages):
            return "预设与源文件不兼容：\(messages.joined(separator: "；"))"
        }
    }
}
