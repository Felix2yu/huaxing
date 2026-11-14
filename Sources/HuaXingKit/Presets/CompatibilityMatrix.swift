import Foundation

// MARK: - Violation

public struct CompatibilityViolation: Sendable, Equatable, CustomStringConvertible {
    public enum Category: Sendable, Equatable {
        case containerCodecMismatch     // webm + x264, gif + audio
        case pixFmtEncoderMismatch      // h264_videotoolbox + 10-bit
        case muxerUnavailable           // m4a without -f ipod
        case toolUnavailable            // requested cjxl but not installed
        case encoderNotInWhitelist      // compile-time catch-all, shouldn't happen
    }
    public var category: Category
    public var message: String

    public init(category: Category, message: String) {
        self.category = category; self.message = message
    }

    public var description: String { message }
}

// MARK: - CompatibilityMatrix

/// Structured validator. NEVER silently rewrites user intent — violations are
/// returned to the caller (rule engine, CLI, GUI) to surface to the user.
public enum CompatibilityMatrix {

    public static func validate(
        preset: Preset,
        source: MediaInfo,
        toolchain: ToolchainSnapshot
    ) -> [CompatibilityViolation] {
        var violations: [CompatibilityViolation] = []

        // MARK: Container × video

        // An audio preset applied to a video file extracts audio (`-vn`), so
        // the source video codec never reaches the output container.
        if preset.kind == .video {
            if let v = preset.video {
                switch preset.container {
                case .webm:
                    if v.encoder != .libvpx_vp9 && v.encoder != .libsvtav1 {
                        violations.append(.init(
                            category: .containerCodecMismatch,
                            message: "WebM 容器只支持 VP9 / AV1 视频编码器"
                        ))
                    }
                case .mp3, .wav, .flac, .ogg:
                    violations.append(.init(
                        category: .containerCodecMismatch,
                        message: "\(preset.container.rawValue.uppercased()) 是音频容器，不能包含视频流"
                    ))
                default:
                    break
                }

                // 10-bit input with h264_videotoolbox is not supported.
                if let pixFmt = source.pixFmt, isTenBit(pixFmt), v.encoder == .h264_videotoolbox {
                    violations.append(.init(
                        category: .pixFmtEncoderMismatch,
                        message: "h264_videotoolbox 不支持 10-bit 输入；请改用 hevc_videotoolbox 或 libx264"
                    ))
                }
            } else if let codec = source.videoCodec {
                // Stream copy mode (`preset.video == nil` → -c:v copy).
                switch preset.container {
                case .webm:
                    if !["vp8", "vp9", "av1"].contains(codec.lowercased()) {
                        violations.append(.init(
                            category: .containerCodecMismatch,
                            message: "WebM 容器不能直接复制 \(codec) 视频流；请选择 VP9/AV1 编码器"
                        ))
                    }
                case .mp3, .wav, .flac, .ogg:
                    violations.append(.init(
                        category: .containerCodecMismatch,
                        message: "\(preset.container.rawValue.uppercased()) 是音频容器，不能包含视频流"
                    ))
                default:
                    break
                }
            }
        }

        // MARK: Container × audio

        if let a = preset.audio {
            if let message = audioMismatch(container: preset.container, encoder: a.encoder) {
                violations.append(.init(category: .containerCodecMismatch, message: message))
            }
        }

        // MARK: Tool availability

        for tool in toolsNeeded(for: preset) {
            if case .failure = toolchain.tools[tool] ?? .failure(.missing) {
                violations.append(.init(
                    category: .toolUnavailable,
                    message: "\(tool.rawValue) 不可用"
                ))
            }
        }

        return violations
    }

    private static func isTenBit(_ pixFmt: String) -> Bool {
        let lower = pixFmt.lowercased()
        return lower.contains("10") || lower.contains("12") || lower.contains("p010") || lower.contains("p016")
    }

    private static func audioMismatch(container: Container, encoder: AudioEncoder) -> String? {
        switch container {
        case .mp3:
            return encoder == .libmp3lame ? nil : "MP3 容器只支持 libmp3lame 音频编码器"
        case .ogg:
            return encoder == .libopus ? nil : "OGG 容器只支持 Opus 音频编码器"
        case .wav:
            return encoder == .pcm_s16le ? nil : "WAV 容器只支持 PCM 16-bit 音频编码器"
        case .flac:
            return encoder == .flac ? nil : "FLAC 容器只支持 FLAC 音频编码器"
        case .webm:
            return encoder == .libopus ? nil : "WebM 容器只支持 Opus 音频编码器"
        case .mp4, .mov, .m4a, .ipod, .mkv:
            // MP4/MOV/M4A do not support raw PCM in practice.
            let supported: Set<AudioEncoder> = [.aac, .aac_at, .alac, .alac_at, .ac3]
            return supported.contains(encoder)
                ? nil
                : "\(container.rawValue.uppercased()) 容器不支持 \(encoder.rawValue) 音频编码器"
        }
    }

    private static func toolsNeeded(for preset: Preset) -> [Tool] {
        if let img = preset.image {
            switch img.target {
            case .jxl: return [.cjxl]
            case .webp: return [.cwebp]
            default: return [] // ImageIO handles the rest natively
            }
        }
        return [.ffmpeg, .ffprobe]
    }
}
