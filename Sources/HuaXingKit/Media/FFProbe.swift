import Foundation

// MARK: - MediaInfo

/// Combined metadata from ffprobe — container-level info + primary stream attributes.
public struct MediaInfo: Sendable, Codable, Equatable {
    public enum Kind: Sendable, Codable, Equatable, CaseIterable { case video, audio, image }

    public var kind: Kind
    public var duration: Double?         // seconds
    public var size: Int64?              // bytes
    public var width: Int?
    public var height: Int?
    public var videoCodec: String?
    public var audioCodec: String?
    public var pixFmt: String?
    public var hasAlpha: Bool
    public var utType: String?           // e.g. "public.mpeg-4"
    public var container: String?        // e.g. "mov,mp4,m4a,3gp,3g2,mj2"

    public init(
        kind: Kind,
        duration: Double? = nil,
        size: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        pixFmt: String? = nil,
        hasAlpha: Bool = false,
        utType: String? = nil,
        container: String? = nil
    ) {
        self.kind = kind
        self.duration = duration
        self.size = size
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.pixFmt = pixFmt
        self.hasAlpha = hasAlpha
        self.utType = utType
        self.container = container
    }
}

// MARK: - FFProbe

public enum FFProbeError: Error, Sendable {
    case executableNotFound
    case probeFailed(String)
    case parseFailed(String)
}

/// Wraps `ffprobe` to extract structured MediaInfo from a file.
public enum FFProbe {
    /// Runs ffprobe on the given URL. `ffprobe` is located via Toolchain or an
    /// explicit path may be provided.
    public static func run(url: URL, ffprobePath: String? = nil) async throws -> MediaInfo {
        let path = try ffprobePath ?? locateFFProbe()

        let spec = ProcessSpec(
            executable: path,
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                url.path
            ],
            timeout: 30
        )
        let result = await ProcessRunner.run(spec)

        guard result.launched else {
            throw FFProbeError.executableNotFound
        }
        if result.exitCode != 0 {
            throw FFProbeError.probeFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return try parseJSON(result.stdout, fileExtension: url.pathExtension)
    }

    /// Image extensions whose ffprobe streams are reported as `codec_type=video`.
    /// ffprobe never emits `codec_type=image`, so extension/container detection is
    /// required to classify still images correctly.
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "avif", "webp", "tiff", "tif",
        "gif", "bmp", "ico", "icns", "exr", "psd", "jp2", "jxl", "j2k", "jpf"
    ]

    private static func locateFFProbe() throws -> String {
        if let found = ToolLocator.resolve(.ffprobe) { return found }
        throw FFProbeError.executableNotFound
    }

    // MARK: - JSON parsing

    private struct ProbeResponse: Decodable {
        var format: FormatBox?
        var streams: [StreamBox]?
    }

    private struct FormatBox: Decodable {
        var duration: String?
        var size: String?
        var format_name: String?
        var tags: TagsBox?
    }

    private struct TagsBox: Decodable {
        var container_fmtp: String?
    }

    private struct StreamBox: Decodable {
        var codec_type: String?
        var codec_name: String?
        var width: Int?
        var height: Int?
        var pix_fmt: String?
        var duration: String?
        var tags: TagsBox?
    }

    private static func parseJSON(_ text: String, fileExtension: String) throws -> MediaInfo {
        guard let data = text.data(using: .utf8) else {
            throw FFProbeError.parseFailed("invalid utf8")
        }
        let resp = try JSONDecoder().decode(ProbeResponse.self, from: data)

        let fmt = resp.format
        let streams = resp.streams ?? []

        // Classify kind from streams. Still images are reported by ffprobe as a
        // single video stream, so extension takes precedence for known image types.
        let hasVideo = streams.contains { $0.codec_type == "video" }
        let hasAudio = streams.contains { $0.codec_type == "audio" }
        let ext = fileExtension.lowercased()

        let kind: MediaInfo.Kind
        if imageExtensions.contains(ext) {
            kind = .image
        } else if hasVideo {
            kind = .video
        } else if hasAudio {
            kind = .audio
        } else {
            kind = .video // fallback
        }

        let duration = fmt?.duration.flatMap(Double.init)
        let size = fmt?.size.flatMap { Int64($0) }

        let videoStream = streams.first { $0.codec_type == "video" }
        let audioStream = streams.first { $0.codec_type == "audio" }

        let pixFmt = videoStream?.pix_fmt

        return MediaInfo(
            kind: kind,
            duration: duration,
            size: size,
            width: videoStream?.width,
            height: videoStream?.height,
            videoCodec: videoStream?.codec_name,
            audioCodec: audioStream?.codec_name,
            pixFmt: pixFmt,
            hasAlpha: pixelFormatHasAlpha(pixFmt),
            utType: utTypeForExtension(ext),
            container: fmt?.format_name
        )
    }

    /// Pixel formats containing an alpha channel. `pixFmt.contains("a")` is not
    /// safe: `gray`, `gray10le` and `pal8` all contain the letter "a".
    private static func pixelFormatHasAlpha(_ pixFmt: String?) -> Bool {
        guard let p = pixFmt?.lowercased() else { return false }
        if p.hasPrefix("gray") || p.hasPrefix("pal") || p.hasPrefix("mono") {
            return false
        }
        return p.contains("a")
    }

    private static func utTypeForExtension(_ ext: String) -> String? {
        let map: [String: String] = [
            "mp4": "public.mpeg-4",
            "mov": "com.apple.quicktime-movie",
            "m4a": "com.apple.m4a-audio",
            "m4v": "com.apple.m4v-video",
            "webm": "org.webmproject.webm",
            "mkv": "org.matroska.mkv",
            "wav": "com.microsoft.waveform-audio",
            "flac": "org.xiph.flac",
            "mp3": "public.mp3",
            "ogg": "org.xiph.ogg",
            "opus": "org.xiph.opus",
            "aiff": "public.aiff-audio",
            "aif": "public.aiff-audio",
            "caf": "com.apple.coreaudio-format",
            "jpg": "public.jpeg",
            "jpeg": "public.jpeg",
            "png": "public.png",
            "webp": "org.webmproject.webp",
            "heic": "public.heic",
            "heif": "public.heif",
            "avif": "public.avif",
            "gif": "com.compuserve.gif",
            "tiff": "public.tiff",
            "tif": "public.tiff",
            "bmp": "com.microsoft.bmp",
            "exr": "com.ilm.openexr-image",
            "psd": "com.adobe.photoshop-image",
            "ico": "com.microsoft.ico",
            "icns": "com.apple.icns",
            "jp2": "public.jpeg-2000",
            "jxl": "public.jpeg-xl"
        ]
        return map[ext.lowercased()]
    }
}
