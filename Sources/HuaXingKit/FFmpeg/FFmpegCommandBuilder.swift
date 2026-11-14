import Foundation

// MARK: - FFmpegCommandBuilder

/// Builds argv arrays for ffmpeg invocations. All container×encoder constraints
/// are enforced here; callers never see `-f ipod` or `scale_vt` vs `scale`.
public enum FFmpegCommandBuilder {

    public static func videoArguments(
        input: URL,
        output: URL,
        preset: Preset
    ) -> [String] {
        var args: [String] = ["-y"]  // overwrite without prompting

        // Input
        // Hardware acceleration prefix — only when videotoolbox encoders are used.
        // `videotoolbox_vld` is required for scale_vt; plain `-hwaccel videotoolbox`
        // keeps frames in software memory so the regular scale filter still works.
        let usesVT = preset.video?.encoder == .h264_videotoolbox
                  || preset.video?.encoder == .hevc_videotoolbox
                  || preset.video?.encoder == .prores_videotoolbox
        let usesScaleVT = usesVT
            && (preset.video?.scaleVt == true)
            && preset.video?.maxWidth != nil
            && preset.video?.maxHeight != nil

        if usesVT {
            args.append(contentsOf: ["-hwaccel", "videotoolbox"])
            if usesScaleVT {
                args.append(contentsOf: ["-hwaccel_output_format", "videotoolbox_vld"])
            }
        }

        args.append(contentsOf: ["-i", input.path])

        // === Video ===
        if let v = preset.video {
            // Scale
            if usesScaleVT, let maxW = v.maxWidth, let maxH = v.maxHeight {
                // scale_vt has no force_original_aspect_ratio option.
                args.append(contentsOf: ["-vf", "scale_vt=w=\(maxW):h=\(maxH)"])
            } else if let maxW = v.maxWidth, let maxH = v.maxHeight {
                args.append(contentsOf: ["-vf", "scale=\(maxW):\(maxH):force_original_aspect_ratio=decrease:force_divisible_by=2"])
            } else if let maxW = v.maxWidth {
                args.append(contentsOf: ["-vf", "scale=\(maxW):-2"])
            } else if let maxH = v.maxHeight {
                args.append(contentsOf: ["-vf", "scale=-2:\(maxH)"])
            }

            // Encoder
            args.append(contentsOf: ["-c:v", v.encoder.flag])

            // AV1 soft-only — never combine with videotoolbox hardwarware chain
            if v.encoder == .libsvtav1 {
                // libsvtav1 soft-encode; drop any -hwaccel already added
                // (our usesVT check above already handles this — libsvtav1 ≠ videotoolbox)
            }

            // Rate control
            if let crf = v.crf { args.append(contentsOf: ["-crf", "\(crf)"]) }
            if let bitrate = v.bitrate { args.append(contentsOf: ["-b:v", bitrate]) }
            if let p = v.preset { args.append(contentsOf: ["-preset", p]) }
        } else {
            args.append(contentsOf: ["-c:v", "copy"])
        }

        // === Audio ===
        if let a = preset.audio {
            args.append(contentsOf: ["-c:a", a.encoder.flag])
            if let br = a.bitrate { args.append(contentsOf: ["-b:a", br]) }
            if let sr = a.sampleRate { args.append(contentsOf: ["-ar", "\(sr)"]) }
            if let ch = a.channels { args.append(contentsOf: ["-ac", "\(ch)"]) }
        } else if preset.kind == .video {
            // Containers that cannot carry AAC get Opus by default.
            let defaultEncoder: AudioEncoder =
                (preset.container == .webm || preset.container == .ogg) ? .libopus : .aac
            args.append(contentsOf: ["-c:a", defaultEncoder.flag])
        }

        // === Container ===
        let fmt = preset.container.ffmpegFormat
        args.append(contentsOf: ["-f", fmt])

        // Output
        args.append(output.path)

        // Progress pipe
        args.append(contentsOf: ["-progress", "pipe:1", "-nostats"])

        return args
    }

    public static func audioArguments(
        input: URL,
        output: URL,
        preset: Preset
    ) -> [String] {
        // -vn is essential: without it ffmpeg keeps the source video stream when
        // the output muxer (e.g. ipod/m4a) accepts video, producing a huge file.
        var args = ["-y", "-i", input.path, "-vn"]
        if let a = preset.audio {
            args.append(contentsOf: ["-c:a", a.encoder.flag])
            if let br = a.bitrate { args.append(contentsOf: ["-b:a", br]) }
            if let sr = a.sampleRate { args.append(contentsOf: ["-ar", "\(sr)"]) }
            if let ch = a.channels { args.append(contentsOf: ["-ac", "\(ch)"]) }
        }
        args.append(contentsOf: ["-f", preset.container.ffmpegFormat])
        args.append(output.path)
        args.append(contentsOf: ["-progress", "pipe:1", "-nostats"])
        return args
    }
}
