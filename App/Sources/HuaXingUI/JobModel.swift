import Foundation
import Combine
import HuaXingKit

// MARK: - JobModel

/// 单个转换任务的完整状态。
///
/// 生命周期：`.pending` → `.running` → `.finished` / `.failed` / `.cancelled`
///
/// 进度通过 `updateProgress(_:)` 从管线的 progress 回调喂入，结果在
/// 管线成功返回时通过 `markFinished(result:)` / `markImageFinished(result:)` 记录。
@MainActor
public final class JobModel: ObservableObject, Identifiable {

    public let id: UUID
    public let inputURL: URL
    public let outputURL: URL
    public let preset: Preset
    public let submittedAt: Date
    /// The rule that produced this job, if any (displayed in the job table).
    public let ruleName: String?
    /// Actions to run after a successful conversion.
    public let postProcessing: [PostProcessStep]
    /// Rule actions can override the preset's metadata flag.
    public let keepMetadata: Bool

    // MARK: - Published state

    @Published public private(set) var status: Status = .pending
    @Published public private(set) var progressFraction: Double = 0   // 0...1
    @Published public private(set) var speedMultiplier: Double?       // e.g. 16.60×
    @Published public private(set) var wallClockSeconds: Double = 0
    @Published public private(set) var inputBytes: Int64?
    @Published public private(set) var outputBytes: Int64?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var metadataLost: Bool = false

    /// ffmpeg 管线返回的完整结果（视频/音频）。
    public var conversionResult: ConversionResult?
    /// 图片管线返回的完整结果。
    public var imageResult: ImagePipeline.ImageConversionResult?

    /// 用于取消运行中的任务。QueueManager 持有对这个 handle 的引用。
    public var cancellationHandle: ProcessHandle?

    // MARK: - Status enum

    public enum Status: String, Sendable, CaseIterable, CustomStringConvertible {
        case pending, running, finished, failed, cancelled
        public var description: String { rawValue }
    }

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        inputURL: URL,
        outputURL: URL,
        preset: Preset,
        submittedAt: Date = Date(),
        ruleName: String? = nil,
        postProcessing: [PostProcessStep] = [],
        keepMetadata: Bool? = nil
    ) {
        self.id = id
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.preset = preset
        self.submittedAt = submittedAt
        self.ruleName = ruleName
        self.postProcessing = postProcessing
        self.keepMetadata = keepMetadata ?? preset.keepMetadata
    }

    // MARK: - State transitions

    public func markRunning() {
        status = .running
        progressFraction = 0
        speedMultiplier = nil
        errorMessage = nil
    }

    public func updateProgress(_ fraction: Double, speed: Double? = nil) {
        progressFraction = min(max(fraction, 0), 1)
        if let speed { speedMultiplier = speed }
    }

    public func markFinished(result: ConversionResult) {
        status = .finished
        conversionResult = result
        wallClockSeconds = result.wallClockSeconds
        inputBytes = result.inputBytes
        outputBytes = result.outputBytes
        progressFraction = 1
    }

    public func markImageFinished(result: ImagePipeline.ImageConversionResult) {
        status = .finished
        imageResult = result
        wallClockSeconds = result.wallClockSeconds
        let attrs = try? FileManager.default.attributesOfItem(atPath: inputURL.path)
        if let size = attrs?[.size] as? NSNumber {
            inputBytes = size.int64Value
        }
        outputBytes = result.outputBytes
        metadataLost = result.metadataLost
        progressFraction = 1
    }

    public func markFailed(_ error: Error) {
        status = .failed
        errorMessage = error.localizedDescription
    }

    public func markCancelled() {
        status = .cancelled
        cancellationHandle?.cancel()
    }

    /// 计算属性 —— 给 SwiftUI 视图用。
    public var isActive: Bool {
        status == .pending || status == .running
    }

    public var isTerminal: Bool {
        status == .finished || status == .failed || status == .cancelled
    }

    /// 输出文件大小的人类可读字符串。
    public var outputBytesFormatted: String {
        ByteCountFormatter.string(fromByteCount: outputBytes ?? 0, countStyle: .file)
    }
}

// ProcessHandle 已是 public + @unchecked Sendable，直接持有即可。
