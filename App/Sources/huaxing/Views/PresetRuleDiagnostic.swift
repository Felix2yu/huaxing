import Foundation
import SwiftUI
import HuaXingKit
import HuaXingUI

// MARK: - PresetEditorView

/// 预设编辑器 —— 左侧 List + 右侧 Form 详情。
struct PresetEditorView: View {
    @EnvironmentObject var appModel: AppModel
    @EnvironmentObject var uiState: UIRuntimeState

    var body: some View {
        NavigationSplitView {
            presetList
        } detail: {
            if let id = uiState.editorSelectedPresetID,
               let index = appModel.presets.firstIndex(where: { $0.id == id }) {
                presetEditor(binding: presetBinding(at: index))
            } else {
                emptyDetail
            }
        }
        .navigationTitle("预设")
    }

    private var presetList: some View {
        List(selection: Binding(
            get: { uiState.editorSelectedPresetID },
            set: { uiState.editorSelectedPresetID = $0 }
        )) {
            ForEach(appModel.presets) { preset in
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.body.weight(.medium))
                    Text(preset.kind.displayName + " · " + preset.container.displayName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(preset.id)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            Button {
                // A fresh preset must be complete for its kind — an empty
                // `video`/`audio`/`image` field would fail at conversion time.
                let newPreset = Preset(
                    name: "新预设", kind: .video, container: .mp4,
                    video: VideoSettings(encoder: .h264_videotoolbox, crf: 23, preset: "medium"),
                    audio: AudioSettings(encoder: .aac, bitrate: "128k")
                )
                appModel.addPreset(newPreset)
                uiState.editorSelectedPresetID = newPreset.id
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    private func presetBinding(at index: Int) -> Binding<Preset> {
        Binding(
            get: { appModel.presets[index] },
            set: { newValue in
                var list = appModel.presets
                list[index] = newValue
                appModel.presets = list
                appModel.updatePreset(newValue)
            }
        )
    }

    private func presetEditor(binding: Binding<Preset>) -> some View {
        PresetForm(preset: binding, onDelete: {
            let id = binding.wrappedValue.id
            appModel.deletePreset(id: id)
            if uiState.editorSelectedPresetID == id { uiState.editorSelectedPresetID = nil }
        })
        .padding(20)
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("从左侧选择一个预设，或新建")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PresetForm

/// 预设编辑 Form —— 按 kind 条件显示 video/audio/image 子表单。
struct PresetForm: View {
    @Binding var preset: Preset
    var onDelete: () -> Void

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("名称", text: $preset.name)
                Picker("类型", selection: $preset.kind) {
                    ForEach(MediaInfo.Kind.allCases, id: \.self) { k in
                        Text(k.displayName).tag(k)
                    }
                }
                Picker("容器", selection: $preset.container) {
                    ForEach(Container.allCases, id: \.self) { c in
                        Text(c.displayName).tag(c)
                    }
                }
            }

            switch preset.kind {
            case .video:
                Section("视频设置") {
                    VideoSettingsForm(video: videoBinding)
                }
                Section("音频设置（可选）") {
                    AudioSettingsForm(audio: audioBinding)
                }
            case .audio:
                Section("音频设置") {
                    AudioSettingsForm(audio: audioBinding)
                }
            case .image:
                Section("图片设置") {
                    ImageSettingsForm(image: imageBinding)
                }
            }

            Section("输出") {
                TextField("输出目录", text: $preset.outputDirectory)
                TextField("命名模板", text: $preset.naming)
                Toggle("保留元数据", isOn: $preset.keepMetadata)
            }

            Section {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除此预设", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: preset.kind) { _, newKind in
            ensureSettings(for: newKind)
            ensureContainer(preset.container)
        }
        .onChange(of: preset.container) { _, newContainer in
            ensureContainer(newContainer)
        }
    }

    /// Keeps the kind-specific settings non-nil so the form is always editable
    /// and conversion never fails on a missing settings block.
    private func ensureSettings(for kind: MediaInfo.Kind) {
        switch kind {
        case .video:
            if preset.video == nil {
                preset.video = VideoSettings(encoder: .h264_videotoolbox, crf: 23, preset: "medium")
            }
            if preset.audio == nil {
                preset.audio = AudioSettings(encoder: .aac, bitrate: "128k")
            }
            preset.image = nil
            if [.mp3, .wav, .flac, .ogg, .m4a, .ipod].contains(preset.container) {
                preset.container = .mp4
            }
        case .audio:
            if preset.audio == nil {
                preset.audio = AudioSettings(encoder: .aac, bitrate: "192k")
            }
            preset.video = nil
            preset.image = nil
            if [.mp4, .mkv, .webm, .mov].contains(preset.container) {
                preset.container = .m4a
            }
        case .image:
            if preset.image == nil {
                preset.image = ImageSettings(target: .jpeg, quality: 90, lossless: false)
            }
            preset.video = nil
            preset.audio = nil
        }
    }

    /// Auto-corrects encoder choices that the selected container cannot carry.
    private func ensureContainer(_ container: Container) {
        switch preset.kind {
        case .video:
            if container == .webm {
                preset.video?.encoder = .libvpx_vp9
                preset.audio?.encoder = .libopus
            } else if preset.video?.encoder == .libvpx_vp9 {
                preset.video?.encoder = .h264_videotoolbox
            }
            if container == .mov || container == .mp4 || container == .mkv {
                if preset.audio?.encoder == .libopus {
                    preset.audio?.encoder = .aac
                }
            }
        case .audio:
            let desired: AudioEncoder
            switch container {
            case .mp3: desired = .libmp3lame
            case .flac: desired = .flac
            case .wav: desired = .pcm_s16le
            case .ogg: desired = .libopus
            default: desired = .aac
            }
            if preset.audio == nil {
                preset.audio = AudioSettings(encoder: desired)
            } else if [.mp3, .flac, .wav, .ogg].contains(container) {
                preset.audio?.encoder = desired
            }
        case .image:
            break
        }
    }

    private var videoBinding: Binding<VideoSettings> {
        Binding(
            get: { preset.video ?? VideoSettings(encoder: .h264_videotoolbox) },
            set: { preset.video = $0 }
        )
    }
    private var audioBinding: Binding<AudioSettings> {
        Binding(
            get: { preset.audio ?? AudioSettings(encoder: .aac) },
            set: { preset.audio = $0 }
        )
    }
    private var imageBinding: Binding<ImageSettings> {
        Binding(
            get: { preset.image ?? ImageSettings(target: .jpeg) },
            set: { preset.image = $0 }
        )
    }
}

// MARK: - VideoSettingsForm

struct VideoSettingsForm: View {
    @Binding var video: VideoSettings

    var body: some View {
        Picker("编码器", selection: $video.encoder) {
            ForEach(VideoEncoder.allCases, id: \.self) { e in
                Text(e.displayName).tag(e)
            }
        }
        TextField("码率（如 3M, 1200k）", text: Binding(
            get: { video.bitrate ?? "" },
            set: { video.bitrate = $0.isEmpty ? nil : $0 }
        ))
        Stepper(value: Binding(
            get: { video.crf ?? 23 },
            set: { video.crf = $0 }
        ), in: 0...51) {
            Text("CRF: \(video.crf ?? 23)")
        }
        HStack {
            TextField("最大宽度", text: Binding(
                get: { video.maxWidth.map(String.init) ?? "" },
                set: { video.maxWidth = Int($0) }
            ))
            TextField("最大高度", text: Binding(
                get: { video.maxHeight.map(String.init) ?? "" },
                set: { video.maxHeight = Int($0) }
            ))
        }
        Toggle("使用 VideoToolbox 缩放", isOn: $video.scaleVt)
    }
}

// MARK: - AudioSettingsForm

struct AudioSettingsForm: View {
    @Binding var audio: AudioSettings

    var body: some View {
        Picker("编码器", selection: $audio.encoder) {
            ForEach(AudioEncoder.allCases, id: \.self) { e in
                Text(e.displayName).tag(e)
            }
        }
        TextField("码率（如 128k）", text: Binding(
            get: { audio.bitrate ?? "" },
            set: { audio.bitrate = $0.isEmpty ? nil : $0 }
        ))
        HStack {
            TextField("采样率（如 48000）", text: Binding(
                get: { audio.sampleRate.map(String.init) ?? "" },
                set: { audio.sampleRate = Int($0) }
            ))
            TextField("声道数", text: Binding(
                get: { audio.channels.map(String.init) ?? "" },
                set: { audio.channels = Int($0) }
            ))
        }
    }
}

// MARK: - ImageSettingsForm

struct ImageSettingsForm: View {
    @Binding var image: ImageSettings

    var body: some View {
        Picker("目标格式", selection: $image.target) {
            ForEach(ImageTarget.allCases, id: \.self) { t in
                Text(t.displayName).tag(t)
            }
        }
        Toggle("无损", isOn: $image.lossless)
        if !image.lossless {
            Stepper(value: Binding(
                get: { image.quality ?? 90 },
                set: { image.quality = $0 }
            ), in: 0...100) {
                Text("质量: \(Int(image.quality ?? 90))")
            }
        }
        HStack {
            TextField("最大宽度", text: Binding(
                get: { image.maxWidth.map(String.init) ?? "" },
                set: { image.maxWidth = Int($0) }
            ))
            TextField("最大高度", text: Binding(
                get: { image.maxHeight.map(String.init) ?? "" },
                set: { image.maxHeight = Int($0) }
            ))
        }
    }
}

// MARK: - RuleEditorView

/// 规则编辑器 v1：单层条件列表，无 all/any/not 递归嵌套。
struct RuleEditorView: View {
    @EnvironmentObject var appModel: AppModel
    @EnvironmentObject var uiState: UIRuntimeState

    var body: some View {
        NavigationSplitView {
            ruleList
        } detail: {
            if let id = uiState.selectedRuleID,
               let index = appModel.rules.firstIndex(where: { $0.id == id }) {
                ruleEditor(binding: ruleBinding(at: index))
            } else {
                emptyDetail
            }
        }
        .navigationTitle("规则")
    }

    private var ruleList: some View {
        List(selection: Binding(
            get: { uiState.selectedRuleID },
            set: { uiState.selectedRuleID = $0 }
        )) {
            ForEach(appModel.rules) { rule in
                HStack {
                    Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(rule.enabled ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name).font(.body.weight(.medium))
                        Text("优先级 \(rule.priority)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .tag(rule.id)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            Button {
                let presetID = appModel.presets.first?.id ?? ""
                let newRule = Rule(
                    name: "新规则",
                    priority: 0,
                    conditions: .mediaKind(is: .video),
                    action: RuleAction(presetID: presetID)
                )
                appModel.addRule(newRule)
                uiState.selectedRuleID = newRule.id
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    private func ruleBinding(at index: Int) -> Binding<Rule> {
        Binding(
            get: { appModel.rules[index] },
            set: { newValue in
                var list = appModel.rules
                list[index] = newValue
                appModel.rules = list
                appModel.updateRule(newValue)
            }
        )
    }

    private func ruleEditor(binding: Binding<Rule>) -> some View {
        RuleForm(rule: binding, presets: appModel.presets)
            .padding(20)
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("从左侧选择一个规则，或新建")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - RuleForm

struct RuleForm: View {
    @Binding var rule: Rule
    let presets: [Preset]

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("规则名称", text: $rule.name)
                Toggle("启用", isOn: $rule.enabled)
                Stepper("优先级: \(rule.priority)", value: $rule.priority, in: 0...1000)
                Toggle("命中后停止", isOn: $rule.stopOnMatch)
            }

            Section("动作") {
                Picker("预设", selection: $rule.action.presetID) {
                    Text("选择预设…").tag("")
                    ForEach(presets) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                TextField("输出目录", text: $rule.action.outputDirectory)
                TextField("命名模板", text: $rule.action.naming)
                Picker("冲突策略", selection: $rule.action.collisionPolicy) {
                    ForEach(CollisionPolicy.allCases, id: \.self) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                Toggle("保留元数据", isOn: $rule.action.keepMetadata)
            }

            Section("转换完成后") {
                Toggle("在访达中显示结果", isOn: postBinding(.revealInFinder))
                Toggle("打开结果文件", isOn: postBinding(.openResult))
                Toggle("将源文件移到废纸篓", isOn: postBinding(.trashSource))
                Text("仅在转换成功时执行；“移到废纸篓”会移动源文件，请谨慎启用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("条件（当前：\(conditionSummary)）") {
                conditionEditor
            }
        }
        .formStyle(.grouped)
    }

    /// postProcessing 是 [PostProcessStep]，用 Binding 把每个步骤映射成一个开关。
    private func postBinding(_ step: PostProcessStep) -> Binding<Bool> {
        Binding(
            get: { rule.action.postProcessing.contains(step) },
            set: { wanted in
                var steps = rule.action.postProcessing
                if wanted {
                    if !steps.contains(step) { steps.append(step) }
                } else {
                    steps.removeAll { $0 == step }
                }
                rule.action.postProcessing = steps
            }
        )
    }

    private var conditionSummary: String {
        rule.conditions.shortDescription
    }

    @ViewBuilder
    private var conditionEditor: some View {
        // v1 简化：只处理 .mediaKind 直接条件
        switch rule.conditions {
        case .mediaKind(let kind):
            Picker("媒体类型", selection: Binding(
                get: { kind },
                set: { rule.conditions = .mediaKind(is: $0) }
            )) {
                ForEach(MediaInfo.Kind.allCases, id: \.self) { k in
                    Text(k.displayName).tag(k)
                }
            }
        default:
            Text("此条件类型的编辑器 v2 提供")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - DiagnosticView

/// 诊断列表 —— 8 条工具诊断 + severity 颜色。
struct DiagnosticView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("工具链诊断")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    if appModel.isRefreshingToolchain {
                        ProgressView("正在重新检测…")
                            .controlSize(.small)
                    }
                    Button {
                        Task { await appModel.refreshToolchain() }
                    } label: {
                        Label("重新探测", systemImage: "arrow.clockwise")
                    }
                    .disabled(appModel.isRefreshingToolchain)
                }

                if let checkedAt = appModel.lastToolchainCheck {
                    Text("上次检测：\(checkedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appModel.diagnostics.isEmpty {
                    ProgressView("正在探测…")
                        .frame(maxWidth: .infinity, maxHeight: 200)
                } else {
                    ForEach(appModel.diagnostics) { diag in
                        DiagnosticRow(diagnostic: diag)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("诊断")
    }
}

struct DiagnosticRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagnostic.tool.displayName)
                    .font(.body.weight(.medium))
                Text(diagnostic.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let cmd = diagnostic.installCommand {
                Button("复制修复命令") { copyToClipboard(cmd) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch diagnostic.severity {
        case .ok:      return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.circle.fill"
        }
    }
    private var color: Color {
        switch diagnostic.severity {
        case .ok:      return .green
        case .warning: return .orange
        case .error:   return .red
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
