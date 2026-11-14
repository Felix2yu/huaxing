import Foundation
import ImageIO

// MARK: - ImageIOBridge

/// Images whose target format is known to be writable by CGImageDestination.
///
/// The list is **enumerated at runtime** (CGImageDestinationCopyTypeIdentifiers())
/// because sips supporting a format ≠ ImageIO being able to write it — and
/// different macOS versions may diverge.
public enum ImageIOBridge {

    public static func writableTypes() -> Set<String> {
        guard let list = CGImageDestinationCopyTypeIdentifiers() as? [String] else {
            return []
        }
        return Set(list)
    }

    /// Decodes a source file to CGImage. Returns nil on unsupported format / missing file.
    ///
    /// - Parameter maxPixelSize: when provided, ImageIO creates a thumbnail no larger
    ///   than this value on the long edge (aspect ratio preserved).
    ///   EXIF orientation is applied, so callers never need to rotate manually.
    public static func decode(_ url: URL, maxPixelSize: Int? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let limit: Int
        if let maxPixelSize, maxPixelSize > 0 {
            limit = maxPixelSize
        } else {
            // Full-size decode still goes through the thumbnail API so EXIF
            // orientation is applied consistently.
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
            limit = max(w, h)
        }

        if limit > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
                return image
            }
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Decodes to PNG bytes — used as an intermediate when cjxl/cwebp can't read the source.
    public static func decodeToPNG(_ url: URL, metadata: CFDictionary? = nil) -> Data? {
        guard let img = decode(url) else { return nil }
        return encodeToPNG(img, with: metadata)
    }

    /// Source metadata (EXIF/GPS/TIFF/IPTC) without orientation and pixel-dimension
    /// keys, so it can be attached to an already-rotated/resized CGImage.
    public static func metadata(of url: URL) -> CFDictionary? {
        guard let props = properties(of: url) else { return nil }
        var dict = props
        dict.removeValue(forKey: kCGImagePropertyOrientation)
        dict.removeValue(forKey: kCGImagePropertyPixelWidth)
        dict.removeValue(forKey: kCGImagePropertyPixelHeight)
        return dict as CFDictionary
    }

    /// Whether the source actually carries user metadata worth reporting as
    /// "lost" (EXIF / GPS / IPTC / TIFF / XMP). `metadata(of:)` is NOT a valid
    /// proxy: ImageIO always returns a dictionary with pixel size / color model
    /// / profile name, even for a freshly generated PNG with no EXIF at all.
    /// Using it would make every JXL/WebP conversion claim metadata loss.
    public static func hasPreservableMetadata(of url: URL) -> Bool {
        guard let props = properties(of: url) else { return false }
        let markers = ["exif", "gps", "iptc", "tiff", "xmp", "jumbf"]
        // ImageIO synthesizes these on every decode — a plain PNG gets an
        // {Exif} box containing only PixelXDimension/PixelYDimension. They are
        // pixel properties, not user metadata.
        let synthesized = [
            "orientation", "pixel", "colorspace", "resolution",
            "interlacetype", "srgbintent", "gamma", "chromaticities"
        ]
        for (key, value) in props {
            let name = key as String
            guard markers.contains(where: { name.localizedCaseInsensitiveContains($0) }) else {
                continue
            }
            if let dict = value as? [AnyHashable: Any] {
                let meaningful = dict.keys.filter { entry in
                    let entryName = "\(entry)"
                    return !synthesized.contains { entryName.localizedCaseInsensitiveContains($0) }
                }
                if !meaningful.isEmpty { return true }
            } else if let data = value as? Data, !data.isEmpty {
                return true
            } else if let string = value as? String, !string.isEmpty {
                return true
            }
        }
        return false
    }

    private static func properties(of url: URL) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return nil
        }
        return props
    }

    /// Scales down to fit within maxWidth/maxHeight, preserving aspect ratio.
    /// Returns the original image when no downscale is needed.
    public static func resized(_ image: CGImage, maxWidth: Int?, maxHeight: Int?) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        guard w > 0, h > 0 else { return image }

        var scale = 1.0
        if let maxWidth, maxWidth > 0 { scale = min(scale, CGFloat(maxWidth) / w) }
        if let maxHeight, maxHeight > 0 { scale = min(scale, CGFloat(maxHeight) / h) }
        guard scale < 1 else { return image }

        let targetW = max(1, Int((w * scale).rounded()))
        let targetH = max(1, Int((h * scale).rounded()))
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage() ?? image
    }

    public static func encodeToPNG(_ image: CGImage, with metadata: CFDictionary? = nil) -> Data? {
        encode(image: image, type: "public.png", quality: nil, metadata: metadata)
    }

    public static func encode(
        image: CGImage,
        type: String,          // UTI, e.g. "public.jpeg"
        quality: Double?,      // 0…1 where supported; nil for lossless formats
        metadata: CFDictionary? = nil
    ) -> Data? {
        var options: [CFString: Any] = [:]
        if let quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }

        guard let data = NSMutableData() as CFMutableData?,
              let dest = CGImageDestinationCreateWithData(
                data, type as CFString, 1, options as CFDictionary
              )
        else { return nil }

        CGImageDestinationAddImage(dest, image, metadata)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Writes `image` directly to disk at `url` — used for ImageIO-native targets.
    public static func write(
        image: CGImage,
        to url: URL,
        type: String,
        quality: Double?,
        metadata: CFDictionary? = nil
    ) throws {
        guard let data = encode(image: image, type: type, quality: quality, metadata: metadata) else {
            throw ImageError.ioEncodeFailed(type)
        }
        try data.write(to: url)
    }
}

// MARK: - JXLBridge

/// JXL encoding/decoding via cjxl / djxl binaries.
///
/// Design note: cjxl input whitelist is JXL/PPM/PNM/PFM/PAM/PGX/PNG/APNG/GIF/JPEG/EXR.
/// **WebP/AVIF/HEIC/TIFF 必须先 ImageIO 解码成 PNG 中间态**再喂 cjxl。那个
/// 中间态 **必然丢 EXIF/XMP** — 本模块不假装保真，调用方通过
/// `ImageConversionResult.metadataLost == true` 告知 UI / CLI。
public struct JXLBridge {
    public let cjxlPath: String
    public let djxlPath: String

    public init(cjxlPath: String, djxlPath: String) {
        self.cjxlPath = cjxlPath
        self.djxlPath = djxlPath
    }

    public struct EncodeOptions: Sendable {
        public enum Mode: Sendable { case distance(Double), quality(Int), losslessJPEG }
        /// -d 0 = mathematically lossless for JPEG input. Default: distance 1 (visually lossless).
        public var mode: Mode = .distance(1)
        /// -e 1…10, default 7
        public var effort: Int = 7
        /// -j — keep JPEG math identity (default on). Disable if input is not JPEG.
        public var losslessJPEG: Bool = true
        /// -p progressive stages (0, 1, 2, 3). Default 1.
        public var progressive: Int = 1
        /// --num_threads (nil = cjxl auto)
        public var threads: Int?

        public init(mode: Mode = .distance(1), effort: Int = 7, losslessJPEG: Bool = true,
                    progressive: Int = 1, threads: Int? = nil) {
            self.mode = mode; self.effort = effort
            self.losslessJPEG = losslessJPEG; self.progressive = progressive; self.threads = threads
        }
    }

    /// Returns nil on subprocess failure. Caller decides whether to retry or abort.
    public func encode(
        input: URL,
        output: URL,
        options: EncodeOptions,
        qualityJPEGIdentity: Bool = true
    ) async throws -> ProcessResult {
        var args: [String] = []

        switch options.mode {
        case .distance(let d): args.append(contentsOf: ["-d", "\(d)"])
        case .quality(let q): args.append(contentsOf: ["-q", "\(q)"])
        case .losslessJPEG: break
        }

        args.append(contentsOf: ["-e", "\(options.effort)"])
        // cjxl 0.12.0: -p short form conflicts with unknown-argument error when
        // followed by a numeric value; use --progressive (bool flag, no value).
        if options.progressive > 0 { args.append("--progressive") }
        args.append(contentsOf: ["--lossless_jpeg=\(options.losslessJPEG ? "1" : "0")"])
        if let t = options.threads { args.append(contentsOf: ["--num_threads", "\(t)"]) }
        args.append(contentsOf: [input.path, output.path])

        return await ProcessRunner.run(ProcessSpec(
            executable: cjxlPath, arguments: args, timeout: 600
        ))
    }

    /// Decodes JXL → target format (e.g. "png" or "jpeg"). djxl reads JXL natively.
    public func decode(input: URL, output: URL, format: String = "png") async throws -> ProcessResult {
        await ProcessRunner.run(ProcessSpec(
            executable: djxlPath,
            arguments: ["--output_format", format, input.path, output.path],
            timeout: 300
        ))
    }
}

// MARK: - WebPBridge

public struct WebPBridge {
    public let cwebpPath: String

    public init(cwebpPath: String) { self.cwebpPath = cwebpPath }

    /// - Parameter preserveMetadata: pass `-metadata all` so EXIF/XMP/ICC from
    ///   a directly readable JPEG/PNG survives the WebP encoding. cwebp's
    ///   default is `none`, which silently strips all of it.
    public func encode(
        input: URL,
        output: URL,
        quality: Int = 80,
        lossless: Bool = false,
        preserveMetadata: Bool = false
    ) async throws -> ProcessResult {
        var args: [String] = []
        if lossless { args.append("-lossless") }
        else { args.append(contentsOf: ["-q", "\(quality)"]) }
        if preserveMetadata { args.append(contentsOf: ["-metadata", "all"]) }
        args.append(contentsOf: [input.path, "-o", output.path])

        return await ProcessRunner.run(ProcessSpec(
            executable: cwebpPath, arguments: args, timeout: 300
        ))
    }
}

// MARK: - ImagePipeline

/// Dispatches an image through the correct bridge based on target + source formats.
/// Also handles PNG-intermediate fallback + tags metadata loss.
public struct ImagePipeline: Sendable {
    public let toolchain: ToolchainSnapshot

    public init(toolchain: ToolchainSnapshot) { self.toolchain = toolchain }

    public struct ImageConversionResult: Sendable, Equatable {
        public var outputURL: URL
        public var outputBytes: Int64?
        /// True only when the source really carried EXIF/XMP/GPS/IPTC metadata,
        /// `keepMetadata` was requested, and a PNG intermediate (resize or an
        /// unsupported input format) could not carry it through. Direct
        /// cjxl/cwebp transcodes and every ImageIO target preserve it.
        public var metadataLost: Bool
        public var wallClockSeconds: Double
    }

    public func run(input: URL, output: URL, target: ImageTarget) async throws -> ImageConversionResult {
        try await run(
            input: input,
            output: output,
            settings: ImageSettings(target: target),
            keepMetadata: true
        )
    }

    /// Full image conversion honoring quality / lossless / resize / metadata settings.
    public func run(
        input: URL,
        output: URL,
        settings: ImageSettings,
        keepMetadata: Bool = true
    ) async throws -> ImageConversionResult {
        let clock = ContinuousClock()
        let started = clock.now

        let target = settings.target
        let sourceExt = input.pathExtension.lowercased()
        // Only claim metadata was lost when the source actually had EXIF/XMP/GPS/IPTC.
        let sourceHasMetadata = ImageIOBridge.hasPreservableMetadata(of: input)
        var tempURL: URL?
        defer {
            if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        }

        // Collision resolution belongs to the caller (RuleExecutor / CLI). Once a
        // concrete output URL has been chosen, a stale file must not make
        // cjxl/cwebp refuse to write — ffmpeg already runs with -y.
        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }

        var metadataLost = false
        let effectiveInput: URL

        switch target {
        case .jxl:
            let whitelist: Set<String> = [
                "jxl", "ppm", "pgm", "pnm", "pfm", "pam", "pgx",
                "png", "apng", "gif", "jpg", "jpeg", "exr"
            ]
            let needsIntermediate = !whitelist.contains(sourceExt)
                || settings.maxWidth != nil
                || settings.maxHeight != nil
            if needsIntermediate {
                effectiveInput = try makePNGIntermediate(
                    input: input, settings: settings,
                    keepMetadata: keepMetadata, tempURL: &tempURL
                )
            } else {
                // cjxl copies Exif/XMP/JUMBF boxes from a directly readable
                // PNG/JPEG/GIF/EXR input — no reason to claim metadata loss.
                effectiveInput = input
            }
            metadataLost = keepMetadata && sourceHasMetadata && needsIntermediate

            guard case .success(let cjxl) = toolchain.tools[.cjxl] ?? .failure(.missing) else {
                throw ImageError.toolUnavailable("cjxl")
            }
            let bridge = JXLBridge(cjxlPath: cjxl.path, djxlPath: "")
            let mode: JXLBridge.EncodeOptions.Mode
            if settings.lossless {
                mode = .distance(0)
            } else if let q = settings.quality {
                mode = .quality(Int(q.rounded()))
            } else {
                mode = .distance(1)
            }
            let opts = JXLBridge.EncodeOptions(mode: mode, effort: 7, losslessJPEG: false)
            let result = try await bridge.encode(input: effectiveInput, output: output, options: opts)
            guard result.launched, result.exitCode == 0 else {
                throw ImageError.encodeFailed("cjxl", result.stderr)
            }

        case .webp:
            let whitelist: Set<String> = ["png", "apng", "jpg", "jpeg"]
            let needsIntermediate = !whitelist.contains(sourceExt)
                || settings.maxWidth != nil
                || settings.maxHeight != nil
            if needsIntermediate {
                effectiveInput = try makePNGIntermediate(
                    input: input, settings: settings,
                    keepMetadata: keepMetadata, tempURL: &tempURL
                )
            } else {
                effectiveInput = input
            }
            metadataLost = keepMetadata && sourceHasMetadata && needsIntermediate

            guard case .success(let cwebp) = toolchain.tools[.cwebp] ?? .failure(.missing) else {
                throw ImageError.toolUnavailable("cwebp")
            }
            let bridge = WebPBridge(cwebpPath: cwebp.path)
            let q = Int((settings.quality ?? 90).rounded())
            let result = try await bridge.encode(
                input: effectiveInput, output: output,
                quality: q, lossless: settings.lossless,
                preserveMetadata: keepMetadata && sourceHasMetadata
            )
            guard result.launched, result.exitCode == 0 else {
                throw ImageError.encodeFailed("cwebp", result.stderr)
            }

        default:
            guard let uti = targetUTI(target) else {
                throw ImageError.unsupportedTarget(target.rawValue)
            }
            guard ImageIOBridge.writableTypes().contains(uti) else {
                throw ImageError.unsupportedTarget(target.rawValue)
            }
            guard let image = ImageIOBridge.decode(input) else {
                throw ImageError.decodeFailed(input.pathExtension)
            }
            let scaled = ImageIOBridge.resized(
                image,
                maxWidth: settings.maxWidth,
                maxHeight: settings.maxHeight
            )
            let meta = keepMetadata ? ImageIOBridge.metadata(of: input) : nil
            try ImageIOBridge.write(
                image: scaled,
                to: output,
                type: uti,
                quality: Self.normalizedQuality(settings.quality),
                metadata: meta
            )
            metadataLost = false
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: output.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value
        guard size != nil, size! > 0 else {
            throw ImageError.encodeFailed(target.rawValue, "输出文件为空")
        }
        let elapsed = VideoPipeline.elapsedSeconds(since: started, clock: clock)

        return ImageConversionResult(
            outputURL: output,
            outputBytes: size,
            metadataLost: metadataLost,
            wallClockSeconds: elapsed
        )
    }

    /// ImageIO expects 0…1, while the CLI and JXL/WebP expose 0…100. Accept
    /// either convention and clamp to the ImageIO range.
    private static func normalizedQuality(_ quality: Double?) -> Double? {
        guard let quality else { return nil }
        let value = quality > 1 ? quality / 100 : quality
        return min(max(value, 0), 1)
    }

    /// Decodes + optionally resizes the source, then writes a PNG intermediate.
    private func makePNGIntermediate(
        input: URL,
        settings: ImageSettings,
        keepMetadata: Bool,
        tempURL: inout URL?
    ) throws -> URL {
        guard let image = ImageIOBridge.decode(input) else {
            throw ImageError.decodeFailed(input.pathExtension)
        }
        let scaled = ImageIOBridge.resized(
            image,
            maxWidth: settings.maxWidth,
            maxHeight: settings.maxHeight
        )
        let metadata = keepMetadata ? ImageIOBridge.metadata(of: input) : nil
        guard let png = ImageIOBridge.encodeToPNG(scaled, with: metadata)
                ?? ImageIOBridge.encodeToPNG(scaled) else {
            throw ImageError.ioEncodeFailed("public.png")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("huaxing-img-\(UUID().uuidString).png")
        try png.write(to: tmp)
        tempURL = tmp
        return tmp
    }

    private func targetUTI(_ t: ImageTarget) -> String? {
        switch t {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        case .tiff: return "public.tiff"
        case .heic: return "public.heic"
        case .heics: return "public.heic-sequence"
        case .avif: return "public.avif"
        case .gif: return "com.compuserve.gif"
        case .bmp: return "com.microsoft.bmp"
        case .ico: return "com.microsoft.ico"
        case .icns: return "com.apple.icns"
        case .exr: return "com.apple.exr-image"
        case .psd: return "com.adobe.photoshop-image"
        case .jp2: return "public.jpeg-2000"
        case .webp, .jxl: return nil  // external tools only
        }
    }
}

// MARK: - ImageError

public enum ImageError: Error, Sendable {
    case decodeFailed(String)
    case encodeFailed(String, String)
    case ioEncodeFailed(String)
    case unsupportedTarget(String)
    case toolUnavailable(String)
}

extension ImageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .decodeFailed(let ext):
            return "无法解码图片（格式：\(ext.isEmpty ? "未知" : ext)）"
        case .encodeFailed(let tool, let message):
            return message.isEmpty
                ? "\(tool) 编码失败"
                : "\(tool) 编码失败：\(VideoPipeline.tail(of: message))"
        case .ioEncodeFailed(let type):
            return "无法写入图片格式：\(type)"
        case .unsupportedTarget(let target):
            return "系统不支持输出格式：\(target)"
        case .toolUnavailable(let tool):
            return "缺少图片转换工具：\(tool)"
        }
    }
}
