import Foundation

// MARK: - ConversionResult

public struct ConversionResult: Sendable, Equatable {
    public var inputURL: URL
    public var outputURL: URL
    public var inputBytes: Int64?
    public var outputBytes: Int64?
    public var wallClockSeconds: Double
    public var peakSpeedMultiplier: Double?
    public var done: Bool

    public init(
        inputURL: URL, outputURL: URL,
        inputBytes: Int64? = nil, outputBytes: Int64? = nil,
        wallClockSeconds: Double = 0, peakSpeedMultiplier: Double? = nil,
        done: Bool = true
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.wallClockSeconds = wallClockSeconds
        self.peakSpeedMultiplier = peakSpeedMultiplier
        self.done = done
    }
}

// MARK: - VideoPipeline

public struct VideoPipeline: Sendable {
    public let ffmpegPath: String

    public init(ffmpegPath: String) { self.ffmpegPath = ffmpegPath }

    public func run(
        input: URL,
        output: URL,
        preset: Preset,
        progress: @Sendable (FFmpegProgress) -> Void = { _ in },
        onStart: (@Sendable (ProcessHandle) -> Void)? = nil
    ) async throws -> ConversionResult {
        let args = FFmpegCommandBuilder.videoArguments(input: input, output: output, preset: preset)

        let clock = ContinuousClock()
        let started = clock.now

        let (stream, handle) = ProcessRunner.lines(ProcessSpec(
            executable: ffmpegPath, arguments: args, timeout: 1800
        ))
        onStart?(handle)

        let parser = FFmpegProgressParser()
        var peakSpeed: Double?
        var stderrTail = ""

        for await line in stream {
            if line.stream == .stderr {
                if stderrTail.count < 8192 { stderrTail += line.text + "\n" }
            }
            let p = parser.parse(line: line.text)
            progress(p)
            if let s = p.speed, peakSpeed == nil || s > peakSpeed! {
                peakSpeed = s
            }
        }

        if handle.isCancelled { throw CancellationError() }
        let exitCode = handle.waitUntilExit()
        if handle.didTimeOut { throw ConversionError.timedOut(output.path) }
        if exitCode != 0 {
            throw ConversionError.processFailed(
                exitCode: exitCode,
                message: Self.tail(of: stderrTail)
            )
        }

        let elapsed = Self.elapsedSeconds(since: started, clock: clock)

        let fileManager = FileManager.default
        let outAttrs = try? fileManager.attributesOfItem(atPath: output.path)
        let size = (outAttrs?[.size] as? NSNumber)?.int64Value
        guard size != nil, size! > 0 else {
            throw ConversionError.outputMissingOrEmpty(output.path)
        }
        let inAttrs = try? fileManager.attributesOfItem(atPath: input.path)
        let inputSize = (inAttrs?[.size] as? NSNumber)?.int64Value

        return ConversionResult(
            inputURL: input, outputURL: output,
            inputBytes: inputSize, outputBytes: size,
            wallClockSeconds: elapsed, peakSpeedMultiplier: peakSpeed,
            done: true
        )
    }

    static func elapsedSeconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
        let d = start.duration(to: clock.now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func tail(of text: String, limit: Int = 2000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.suffix(limit))
    }
}

// MARK: - AudioPipeline

public struct AudioPipeline: Sendable {
    public let ffmpegPath: String

    public init(ffmpegPath: String) { self.ffmpegPath = ffmpegPath }

    public func run(
        input: URL, output: URL, preset: Preset,
        progress: @Sendable (FFmpegProgress) -> Void = { _ in },
        onStart: (@Sendable (ProcessHandle) -> Void)? = nil
    ) async throws -> ConversionResult {
        let args = FFmpegCommandBuilder.audioArguments(input: input, output: output, preset: preset)

        let clock = ContinuousClock()
        let started = clock.now

        let (stream, handle) = ProcessRunner.lines(ProcessSpec(
            executable: ffmpegPath, arguments: args, timeout: 600
        ))
        onStart?(handle)

        let parser = FFmpegProgressParser()
        var stderrTail = ""
        for await line in stream {
            if line.stream == .stderr, stderrTail.count < 8192 {
                stderrTail += line.text + "\n"
            }
            parser.parse(line: line.text)
            progress(parser.current)
        }

        if handle.isCancelled { throw CancellationError() }
        let exitCode = handle.waitUntilExit()
        if handle.didTimeOut { throw ConversionError.timedOut(output.path) }
        if exitCode != 0 {
            throw ConversionError.processFailed(
                exitCode: exitCode,
                message: VideoPipeline.tail(of: stderrTail)
            )
        }

        let elapsed = VideoPipeline.elapsedSeconds(since: started, clock: clock)
        let attrs = try? FileManager.default.attributesOfItem(atPath: output.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value
        guard size != nil, size! > 0 else {
            throw ConversionError.outputMissingOrEmpty(output.path)
        }
        let inAttrs = try? FileManager.default.attributesOfItem(atPath: input.path)
        let inputSize = (inAttrs?[.size] as? NSNumber)?.int64Value
        return ConversionResult(
            inputURL: input, outputURL: output,
            inputBytes: inputSize, outputBytes: size,
            wallClockSeconds: elapsed, done: true
        )
    }
}

// MARK: - Errors

public enum ConversionError: Error, Sendable {
    case outputMissingOrEmpty(String)
    case processFailed(exitCode: Int32, message: String)
    case timedOut(String)
}

extension ConversionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .outputMissingOrEmpty(let path):
            return "转换没有生成有效输出文件：\(path)"
        case .processFailed(let code, let message):
            return message.isEmpty
                ? "ffmpeg 转换失败（退出码 \(code)）"
                : "ffmpeg 转换失败（退出码 \(code)）：\(message)"
        case .timedOut(let path):
            return "转换超时：\(path)"
        }
    }
}
