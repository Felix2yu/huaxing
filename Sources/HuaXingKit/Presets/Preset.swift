import Foundation

// MARK: - EncoderCatalog

/// Whitelist of encoders verified available on this machine. Anything not listed
/// here is a compile-time impossibility — the type system prevents callers
/// from asking for libaom-av1 or libwebp which brew ffmpeg doesn't include.
public enum VideoEncoder: String, Sendable, Codable, CaseIterable {
    case libx264
    case libx265
    case h264_videotoolbox
    case hevc_videotoolbox
    case prores_ks
    case prores_videotoolbox
    case libsvtav1
    case libvpx_vp9

    public var flag: String {
        switch self {
        case .libx264, .libx265, .libsvtav1, .libvpx_vp9, .prores_ks:
            return self.rawValue
        case .h264_videotoolbox, .hevc_videotoolbox, .prores_videotoolbox:
            return self.rawValue  // ffmpeg uses the same name for videotoolbox encoders
        }
    }
}

public enum AudioEncoder: String, Sendable, Codable, CaseIterable, Hashable {
    case aac
    case aac_at
    case libopus
    case libmp3lame
    case flac
    case alac
    case alac_at
    case pcm_s16le
    case ac3

    public var flag: String { self.rawValue }
}

/// Image targets — either CGImageDestination-available or external tools only.
public enum ImageTarget: String, Sendable, Codable, CaseIterable {
    case jpeg, png, tiff, heic, heics, avif, gif, bmp, ico, icns, exr, psd, jp2
    case webp, jxl  // external tools only
}

// MARK: - Container

public enum Container: String, Sendable, Codable, CaseIterable {
    case mp4, mkv, webm, mov, m4a, mp3, wav, flac, ogg, ipod
    // ipod = ffmpeg's m4a muxer alias

    public var ffmpegFormat: String {
        switch self {
        case .mp4, .mov: return "mp4"
        case .mkv: return "matroska"
        case .webm: return "webm"
        case .m4a: return "ipod"    // ffmpeg has no standalone m4a muxer
        case .mp3: return "mp3"
        case .wav: return "wav"
        case .flac: return "flac"
        case .ogg: return "ogg"
        case .ipod: return "ipod"
        }
    }

    public var hasAudio: Bool {
        switch self {
        case .mp4, .mkv, .webm, .mov, .m4a, .mp3, .wav, .flac, .ogg:
            return true
        case .ipod: return true
        }
    }
}

// MARK: - Preset

/// A complete conversion recipe. All fields Codable & Sendable so presets can
/// be stored as JSON and passed across actor boundaries.
public struct Preset: Sendable, Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var kind: MediaInfo.Kind
    public var container: Container
    public var video: VideoSettings?
    public var audio: AudioSettings?
    public var image: ImageSettings?
    public var naming: String
    public var outputDirectory: String
    public var keepMetadata: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: MediaInfo.Kind,
        container: Container,
        video: VideoSettings? = nil,
        audio: AudioSettings? = nil,
        image: ImageSettings? = nil,
        naming: String = "{name}",
        outputDirectory: String = "~/Desktop",
        keepMetadata: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.container = container
        self.video = video
        self.audio = audio
        self.image = image
        self.naming = naming
        self.outputDirectory = outputDirectory
        self.keepMetadata = keepMetadata
    }
}

public struct VideoSettings: Sendable, Codable, Equatable {
    public var encoder: VideoEncoder
    public var bitrate: String?       // e.g. "5M", "2000k"
    public var crf: Int?             // quality: 0-51, lower=better (libx264/libx265)
    public var preset: String?       // "ultrafast"…"veryslow"
    public var maxWidth: Int?
    public var maxHeight: Int?
    public var scaleVt: Bool         // use scale_vt for full videotoolbox chain

    public init(
        encoder: VideoEncoder,
        bitrate: String? = nil,
        crf: Int? = nil,
        preset: String? = nil,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        scaleVt: Bool = false
    ) {
        self.encoder = encoder
        self.bitrate = bitrate
        self.crf = crf
        self.preset = preset
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.scaleVt = scaleVt
    }
}

public struct AudioSettings: Sendable, Codable, Equatable {
    public var encoder: AudioEncoder
    public var bitrate: String?
    public var sampleRate: Int?
    public var channels: Int?

    public init(
        encoder: AudioEncoder,
        bitrate: String? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil
    ) {
        self.encoder = encoder
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public struct ImageSettings: Sendable, Codable, Equatable {
    public var target: ImageTarget
    public var quality: Double?        // 0-1 for ImageIO, 0-100 for cjxl, 0-100 for cwebp
    public var maxWidth: Int?
    public var maxHeight: Int?
    public var lossless: Bool          // JXL: -j 1 equivalent

    public init(
        target: ImageTarget,
        quality: Double? = nil,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        lossless: Bool = true
    ) {
        self.target = target
        self.quality = quality
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.lossless = lossless
    }
}

// MARK: - Output extension

public extension Container {
    /// File extension for this container (`m4a` and `ipod` both yield `m4a`).
    var fileExtension: String {
        switch self {
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
}

public extension ImageTarget {
    /// File extension for this image target.
    var fileExtension: String {
        switch self {
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
        case .webp: return "webp"
        case .jxl: return "jxl"
        }
    }
}

public extension Preset {
    /// Natural output extension determined by the preset's kind.
    var outputExtension: String {
        if let image { return image.target.fileExtension }
        return container.fileExtension
    }
}
