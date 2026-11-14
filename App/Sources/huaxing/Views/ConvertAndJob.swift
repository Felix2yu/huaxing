import SwiftUI
import HuaXingKit
import HuaXingUI
import UniformTypeIdentifiers

// MARK: - ConvertDropZone

/// 主拖放区 —— .dropDestination 接受文件/文件夹，配合预设选择和输出目录。
struct ConvertDropZone: View {
    @EnvironmentObject var appModel: AppModel
    @EnvironmentObject var queueManager: QueueManager
    @EnvironmentObject var uiState: UIRuntimeState

    var body: some View {
        VStack(spacing: 24) {
            // 大拖放区
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.secondary.opacity(0.4), lineWidth: 2)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }
                .frame(minHeight: 240)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text("拖拽文件或文件夹到此处")
                            .font(.title2.weight(.semibold))
                        Text("支持视频 / 音频 / 图片格式")
                            .foregroundStyle(.secondary)
                        if uiState.isProcessingDrop {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .padding(24)
                .dropDestination(for: URL.self) { urls, _ in
                    Task { await queueDrop(urls: urls) }
                    return true
                }

            // 控制行
            HStack(spacing: 16) {
                PresetComboBox()
                    .frame(minWidth: 200)

                Toggle("自动匹配规则", isOn: $uiState.useRulesForDrop)
                    .toggleStyle(.checkbox)
                    .help("拖入文件时先按规则选择预设和输出目录，未命中再使用手动预设")

                Spacer()

                OutputDirectoryPicker()

                Button {
                    startConversion()
                } label: {
                    Label("开始转换", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .fileImporter(
                    isPresented: Binding(
                        get: { uiState.showFilePicker },
                        set: { uiState.showFilePicker = $0 }
                    ),
                    allowedContentTypes: [.movie, .audio, .image, .directory],
                    allowsMultipleSelection: true
                ) { result in
                    guard case .success(let urls) = result else { return }
                    Task { await queueDrop(urls: urls) }
                }
            }

            if let error = uiState.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let summary = uiState.lastDropSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .navigationTitle("转换")
    }

    /// 规则模式下不必先选手动预设/输出目录；否则至少要有一个手动预设。
    private var canStart: Bool {
        if uiState.useRulesForDrop && appModel.rules.contains(where: { $0.enabled }) {
            return true
        }
        return uiState.convertPresetID != nil
    }

    // MARK: - Drop handling

    private func queueDrop(urls: [URL]) async {
        uiState.isProcessingDrop = true
        uiState.lastError = nil
        uiState.lastDropSummary = nil
        defer { uiState.isProcessingDrop = false }

        let manualPreset = uiState.convertPresetID.flatMap { id in
            appModel.presets.first { $0.id == id }
        }
        let rulesEnabled = uiState.useRulesForDrop
            && appModel.rules.contains { $0.enabled }

        guard manualPreset != nil || rulesEnabled else {
            uiState.lastError = "请先选择一个预设，或启用一条规则"
            return
        }

        let files = collectFiles(from: urls)
        guard !files.isEmpty else {
            uiState.lastError = "没有找到可转换的媒体文件"
            return
        }

        var queued = 0
        var skipped = 0
        var failures: [String] = []

        for file in files {
            do {
                let jobID: UUID?
                if rulesEnabled {
                    // 规则决定预设、输出目录、命名模板、冲突策略与后处理；
                    // 未命中时回退到手动预设（或该预设自己的输出目录）。
                    jobID = try await queueManager.submit(
                        input: file,
                        fallbackPreset: manualPreset,
                        fallbackDirectory: uiState.outputDirectory,
                        rules: appModel.rules,
                        presets: appModel.presets
                    )
                } else {
                    guard let preset = manualPreset else { break }
                    let directory = uiState.outputDirectory ?? URL(
                        fileURLWithPath: (preset.outputDirectory as NSString).expandingTildeInPath,
                        isDirectory: true
                    )
                    jobID = await queueManager.submit(
                        input: file, outputDirectory: directory, preset: preset
                    )
                }
                if jobID == nil { skipped += 1 } else { queued += 1 }
            } catch {
                failures.append("\(file.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        var parts = ["已入队 \(queued) 项"]
        if rulesEnabled { parts.append("规则模式") }
        if skipped > 0 { parts.append("按冲突策略跳过 \(skipped) 项") }
        if !failures.isEmpty { parts.append("失败 \(failures.count) 项") }
        uiState.lastDropSummary = parts.joined(separator: " · ")
        if !failures.isEmpty {
            uiState.lastError = failures.prefix(3).joined(separator: "；")
        }
        // 有任务入队后直接跳到作业页，让用户看到进度。
        if queued > 0 { uiState.selectedTab = .jobs }
    }

    /// Media extensions that ffmpeg/ImageIO understand. UTType alone is not
    /// enough: some containers (mkv, webm, jxl) have no registered system type.
    private static let mediaExtensions: Set<String> = [
        // video
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "mpg", "mpeg", "ts", "m2ts",
        "3gp", "flv", "wmv", "ogv",
        // audio
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "aiff", "aif",
        "wma", "caf", "alac",
        // image
        "jpg", "jpeg", "png", "heic", "heif", "avif", "webp", "tiff", "tif",
        "gif", "bmp", "jp2", "jxl", "exr", "psd", "ico", "icns"
    ]

    private func isMediaFile(_ url: URL) -> Bool {
        if Self.mediaExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .movie)
            || type.conforms(to: .audio)
            || type.conforms(to: .image)
            || type.conforms(to: .audiovisualContent)
    }

    private func collectFiles(from urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            guard !url.lastPathComponent.hasPrefix("."), isMediaFile(url) else { return }
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            result.append(url)
        }

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let item as URL in enumerator {
                    let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
                    guard values?.isRegularFile == true, values?.isHidden != true else { continue }
                    append(item)
                }
            } else {
                append(url)
            }
        }
        return result
    }

    private func startConversion() {
        uiState.showFilePicker = true
    }
}

// MARK: - PresetComboBox

/// 下拉选预设。
struct PresetComboBox: View {
    @EnvironmentObject var appModel: AppModel
    @EnvironmentObject var uiState: UIRuntimeState

    var body: some View {
        Picker("预设", selection: Binding(
            get: { uiState.convertPresetID ?? "" },
            set: { uiState.convertPresetID = $0.isEmpty ? nil : $0 }
        )) {
            Text("选择预设…").tag("")
            ForEach(appModel.presets) { preset in
                Text("\(preset.name) — \(preset.kind.displayName)")
                    .tag(preset.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }
}

// MARK: - OutputDirectoryPicker

/// 输出目录选择按钮 —— .fileImporter 选目录。
struct OutputDirectoryPicker: View {
    @EnvironmentObject var uiState: UIRuntimeState

    var body: some View {
        HStack(spacing: 4) {
            Button {
                uiState.showDirectoryPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(uiState.outputDirectory?.lastPathComponent ?? "跟随预设/规则目录")
                        .lineLimit(1)
                }
            }
            .help("未选择时：命中规则用规则的输出目录，否则用预设自己的输出目录")

            // 清除全局目录，让规则/预设的 outputDirectory 生效。
            if uiState.outputDirectory != nil {
                Button {
                    uiState.outputDirectory = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除全局目录，改用规则/预设中配置的目录")
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { uiState.showDirectoryPicker },
                set: { uiState.showDirectoryPicker = $0 }
            ),
            allowedContentTypes: [.directory],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                uiState.outputDirectory = url
            }
        }
    }
}

// MARK: - JobListView

/// 作业列表 —— Table 9 列 + 右键菜单。
struct JobListView: View {
    @EnvironmentObject var queueManager: QueueManager
    @EnvironmentObject var uiState: UIRuntimeState

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if queueManager.jobs.isEmpty {
                emptyState
            } else {
                jobTable
            }
        }
        .navigationTitle("作业")
    }

    private var headerBar: some View {
        HStack {
            Text("共 \(queueManager.jobs.count) 个任务")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("取消全部") { queueManager.cancelAll() }
                .disabled(!queueManager.jobs.contains { $0.isActive })
            Button("清除已完成") { queueManager.clearTerminal() }
                .disabled(!queueManager.jobs.contains { $0.isTerminal })
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("还没有转换任务")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var jobTable: some View {
        Table(queueManager.jobs, selection: Binding(
            get: { uiState.selectedJobIDs },
            set: { uiState.selectedJobIDs = $0 }
        )) {
            TableColumn("名称") { job in
                Text(job.inputURL.lastPathComponent).lineLimit(1)
            }
            TableColumn("状态") { job in
                StatusBadge(status: job.status)
            }
            TableColumn("进度") { job in
                ProgressBar(fraction: job.progressFraction, speed: job.speedMultiplier)
            }
            TableColumn("输入") { job in
                Text(byteText(job.inputBytes))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TableColumn("输出") { job in
                Text(byteText(job.outputBytes))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TableColumn("耗时") { job in
                Text(timeText(job.wallClockSeconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TableColumn("预设") { job in
                Text(job.preset.name).lineLimit(1)
            }
            TableColumn("规则") { job in
                if let ruleName = job.ruleName {
                    Text(ruleName).font(.caption).lineLimit(1)
                } else {
                    Text("手动").font(.caption).foregroundStyle(.tertiary)
                }
            }
            TableColumn("元数据") { job in
                if job.metadataLost {
                    Label("已丢失", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("—").font(.caption).foregroundStyle(.tertiary)
                }
            }
            TableColumn("错误") { job in
                if let msg = job.errorMessage {
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("取消选中") {
                ids.forEach { queueManager.cancel(jobID: $0) }
            }
            Button("清除所有已完成项") {
                queueManager.clearTerminal()
            }
        }
    }

    private func byteText(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func timeText(_ seconds: Double) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%dm%02ds", m, s)
    }
}

// MARK: - Components

struct StatusBadge: View {
    let status: JobModel.Status

    private var style: (Color, String) {
        switch status {
        case .pending:   return (.secondary, "等待中")
        case .running:   return (.blue, "运行中")
        case .finished:  return (.green, "完成")
        case .failed:    return (.red, "失败")
        case .cancelled: return (.orange, "取消")
        }
    }

    var body: some View {
        let (color, text) = style
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }
}

struct ProgressBar: View {
    let fraction: Double
    let speed: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: fraction)
            HStack {
                Text("\(Int(fraction * 100))%").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let speed, !speed.isZero {
                    Text(String(format: "%.1f×", speed))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
