import Foundation

// MARK: - FFmpegProgress

/// Parsed progress values from `ffmpeg -progress pipe:1` key=value stream.
public struct FFmpegProgress: Sendable, Equatable {
    /// Number of frames processed so far.
    public var frame: Int?
    /// Frames per second.
    public var fps: Double?
    /// Output time in microseconds — ffmpeg reports both `out_time_us` and
    /// `out_time_ms`; both are treated as microseconds (historical ffmpeg quirk).
    public var outTimeMicroseconds: Int64?
    /// Total output bytes written.
    public var totalSize: Int64?
    /// Current bitrate in bits per second (ffmpeg reports "kbits/s" or empty).
    public var bitrateBps: Double?
    /// Processing speed multiplier (e.g. "1.5x").
    public var speed: Double?
    /// True when progress=end has been seen.
    public var done: Bool

    public init(
        frame: Int? = nil,
        fps: Double? = nil,
        outTimeMicroseconds: Int64? = nil,
        totalSize: Int64? = nil,
        bitrateBps: Double? = nil,
        speed: Double? = nil,
        done: Bool = false
    ) {
        self.frame = frame
        self.fps = fps
        self.outTimeMicroseconds = outTimeMicroseconds
        self.totalSize = totalSize
        self.bitrateBps = bitrateBps
        self.speed = speed
        self.done = done
    }
}

// MARK: - FFmpegProgressParser

/// Incremental parser for the `ffmpeg -progress pipe:1` key=value protocol.
///
/// Usage: create an instance, then call `parse(line:)` for each OutputLine from
/// ProcessRunner.lines. The accumulated state is returned as FFmpegProgress.
public final class FFmpegProgressParser: @unchecked Sendable {
    private var progress = FFmpegProgress()

    /// Parse one line. Pass `stream: .stderr` lines too — some ffmpeg versions
    /// interleave progress on stderr.
    @discardableResult
    public func parse(line: String) -> FFmpegProgress {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return progress }

        // Block boundary — "progress=continue" or "progress=end"
        if trimmed.hasPrefix("progress=") {
            let value = String(trimmed.dropFirst("progress=".count))
            if value == "end" {
                progress.done = true
            } else if value == "continue" {
                progress.done = false
            }
            return progress
        }

        // Ignore lines without '=' (ffmpeg banner, stats, etc.)
        guard let eq = trimmed.firstIndex(of: "=") else { return progress }
        let key = String(trimmed[..<eq]).lowercased()
        let value = String(trimmed[trimmed.index(after: eq)...])

        switch key {
        case "frame":
            progress.frame = Int(value)
        case "fps":
            progress.fps = Double(value)
        case "out_time_us", "out_time_ms":
            // BOTH are microseconds despite the legacy naming of out_time_ms.
            // See ffmpeg source: libavcodec/utils.c line ~2260.
            progress.outTimeMicroseconds = Int64(value)
        case "total_size", "size":
            progress.totalSize = Int64(value)
        case "bitrate":
            // Values come as "12345.6kbits/s" or empty string.
            if let num = extractBitrateKbps(value) {
                progress.bitrateBps = num * 1000
            } else if let plain = Double(value), plain > 0 {
                progress.bitrateBps = plain
            }
        case "speed":
            // "1.2x" or "0.8x"
            if let s = value.firstIndex(of: "x") {
                let numPart = String(value[..<s])
                progress.speed = Double(numPart)
            } else if let plain = Double(value) {
                progress.speed = plain
            }
        default:
            break
        }

        return progress
    }

    /// Current snapshot of accumulated progress.
    public var current: FFmpegProgress { progress }

    // MARK: - Helpers

    private func extractBitrateKbps(_ value: String) -> Double? {
        // Match number + optional "kbits/s" suffix
        let cleaned = value.replacingOccurrences(
            of: "[^0-9.]",
            with: "",
            options: .regularExpression
        )
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }
}
