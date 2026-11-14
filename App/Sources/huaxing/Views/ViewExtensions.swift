import Foundation
import HuaXingKit

// MARK: - Display name extensions for SwiftUI pickers

extension MediaInfo.Kind {
    var displayName: String {
        switch self {
        case .video: return "视频"
        case .audio: return "音频"
        case .image: return "图片"
        }
    }
}

extension Container {
    var displayName: String {
        switch self {
        case .mp4: return "MP4"
        case .mkv: return "MKV"
        case .webm: return "WebM"
        case .mov: return "MOV"
        case .m4a: return "M4A"
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .flac: return "FLAC"
        case .ogg: return "OGG"
        case .ipod: return "iPod (m4a muxer)"
        }
    }
}

extension ImageTarget {
    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
        case .heics: return "HEIC 序列"
        case .avif: return "AVIF"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .ico: return "ICO"
        case .icns: return "ICNS"
        case .exr: return "EXR"
        case .psd: return "PSD"
        case .jp2: return "JPEG 2000"
        case .webp: return "WebP"
        case .jxl: return "JPEG XL"
        }
    }
}

extension VideoEncoder {
    var displayName: String {
        switch self {
        case .libx264: return "H.264 (libx264)"
        case .libx265: return "HEVC (libx265)"
        case .h264_videotoolbox: return "H.264 (VideoToolbox)"
        case .hevc_videotoolbox: return "HEVC (VideoToolbox)"
        case .prores_ks: return "ProRes (libprores_ks)"
        case .prores_videotoolbox: return "ProRes (VideoToolbox)"
        case .libsvtav1: return "AV1 (SVT-AV1)"
        case .libvpx_vp9: return "VP9 (libvpx)"
        }
    }
}

extension AudioEncoder {
    var displayName: String {
        switch self {
        case .aac: return "AAC (fdk)"
        case .aac_at: return "AAC (AudioToolbox)"
        case .libopus: return "Opus"
        case .libmp3lame: return "MP3 (LAME)"
        case .flac: return "FLAC"
        case .alac: return "ALAC"
        case .alac_at: return "ALAC (AudioToolbox)"
        case .pcm_s16le: return "PCM 16-bit"
        case .ac3: return "AC3"
        }
    }
}

extension CollisionPolicy {
    var displayName: String {
        switch self {
        case .overwrite: return "覆盖"
        case .skip: return "跳过"
        case .rename: return "自动重命名"
        }
    }
}

extension Tool {
    var displayName: String {
        switch self {
        case .ffmpeg: return "ffmpeg"
        case .ffprobe: return "ffprobe"
        case .cjxl: return "cjxl"
        case .djxl: return "djxl"
        case .jxlinfo: return "jxlinfo"
        case .cwebp: return "cwebp"
        case .dwebp: return "dwebp"
        case .sips: return "sips"
        }
    }
}

extension RuleCondition {
    var shortDescription: String {
        switch self {
        case .mediaKind(let k): return "媒体类型 = \(k.displayName)"
        case .utType(let u): return "UTType = \(u)"
        case .extension(let exts): return "扩展名 ∈ [\(exts.joined(separator: ", "))]"
        case .fileSize(let min, let max): return "文件大小 \(formatBytes(min))…\(formatBytes(max))"
        case .resolution(let w, let h): return "分辨率 ≥ \(w ?? 0)×\(h ?? 0)"
        case .duration(let min, let max):
            let maxStr: String
            if let max { maxStr = String(max) } else { maxStr = "?" }
            return "时长 \(min ?? 0)…\(maxStr)s"
        case .videoCodec(let c): return "视频编码 ∈ [\(c.joined(separator: ", "))]"
        case .audioCodec(let c): return "音频编码 ∈ [\(c.joined(separator: ", "))]"
        case .filenameGlob(let p): return "文件名匹配 \(p)"
        case .sourceDirectory(let path, let rec): return "源目录 \(path)\(rec ? " (递归)" : "")"
        case .hasAlpha(let b): return "含 alpha = \(b)"
        case .all: return "全部满足（嵌套条件）"
        case .any: return "任一满足（嵌套条件）"
        case .not: return "不满足（嵌套条件）"
        }
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "?" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
