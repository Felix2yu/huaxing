# M10 —— SwiftUI 视图层

> **实现状态说明**：本文件为 M10 的规划稿，下列「文件结构」中的细粒度拆分（`ConvertDropZone` / `JobListView` / `PresetEditorView` / `RuleEditorView` / `DiagnosticView` / `Components/*`）在实际落地时已**合并**为 `App/Sources/huaxing/Views/` 下的 `ConvertAndJob.swift`、`PresetRuleDiagnostic.swift`、`ViewExtensions.swift`、`HuaXingRoot.swift`。功能目标与验收清单不变，仅文件组织更紧凑。

> **前置**：M0-M9 全部完成。根包 HuaXingKit + CLI 可编可跑；App 子包模型层（AppModel/JobModel/QueueManager）`make check-model` 全过；App 子包 release 构建 128 target 全过；三步探针 arm64 直接通过。

## Context

HuaXingKit 引擎 + CLI + App 模型层已全部就位，`HuaXingMain.swift` 的 `ContentView` 仍是占位符（一个 wand 图标 + "SwiftUI probe — OK"）。M10 的目标是把这个占位符替换成**可拖拽入队、可看进度、可编辑规则/预设、可跑诊断**的完整 SwiftUI 界面，一次提交可在本机 `make app` 得到可打开的 `.app`。

**硬约束已解除**：原始 M0-M9 规划里"本机连 arm64 SwiftUI interface 都没有、也缺 libSwiftUIMacros"的假设已被 M9 实测推翻——`make check-ui` 三步探针 arm64 直接过（WindowGroup 需显式 title 字符串，无 @State/@Binding 宏，纯 Combine ObservableObject 路线），App 子包 `swift build -c release` 128 target 全部成功。M10 可以**完整写 SwiftUI 并本机验证**，不再是"只签名核对"。

**沿用的绕宏策略**（原始规划 §5 拍板，M10 继承）：
- `AppModel / JobModel / QueueManager: ObservableObject` + `@Published`（Combine，无宏）
- 根视图 `@StateObject private var model = AppModel()`（纯 propertyWrapper，无宏）
- 子视图 `@EnvironmentObject var model: AppModel`（同上）
- 数组元素双向绑定 `Binding(get: { model.items[i] }, set: { model.items[i] = $0 })` —— 不用 `$model.items[i]`（后者是 Swift 6 严格并发下的 Closure Capture 问题）
- **不用** `@State / @Binding / @AppStorage / #Preview / SwiftData @Model` —— 全部走 ObservableObject 单一路线

---

## 已实测确认的视图层能力边界

**SwiftUI / SwiftUICore**（macOS 26 SDK / target arm64-apple-macos26.0 / CLT）：
- `NavigationSplitView` 有 `.columnVisibility(.all)`、`.navigationSplitViewColumnWidth(min:ideal:max:)` —— 侧栏可宽 200-280
- `WindowGroup("title") { ... }` —— macOS 26 Window 签名变了（需 `id` 参数），但 WindowGroup 无此要求
- `Table`：`TableColumnBuilder.buildBlock` 参数上限 **10** —— 计划 9 列（名称/状态/进度/输入/输出/耗时/预设/规则/错误）不触顶
- `.dropDestination(for: URL.self, isEnabled: true) { items, session in ... }` —— 无 Binding 参数，直接接受
- Liquid Glass：`.glassEffect(.regular, in: .rect(cornerRadius: 12))`、`.backgroundExtensionEffect()`、`.scrollEdgeEffectStyle(.soft, for: .top)` —— 签名已在原始规划核实
- `Commands` 组 + `.commandMenu` 已确认可用（ntfyx 同款）

**模型层现有 API 必须按此签名调用**（详细见 `docs/API_AUDIT.md`，**每次模型层改动必须同步更新该文档**）：

```swift
// AppModel —— 视图主要依赖
appModel.presets          // @Published [Preset]
appModel.rules            // @Published [Rule]
appModel.diagnostics      // @Published [Diagnostic]
appModel.toolchainSnapshot // @Published ToolchainSnapshot?
appModel.addPreset(_:) / updatePreset(_:) / deletePreset(id:)
appModel.addRule(_:) / updateRule(_:) / deleteRule(id:) / toggleRule(id:)
appModel.refreshToolchain() async
appModel.ffmpegPath / cjxlPath / cwebpPath  // String? 便利访问

// QueueManager —— 视图主要依赖
queueManager.jobs         // @Published [JobModel]
queueManager.maxConcurrent // @Published Int
queueManager.isRunning    // @Published Bool
queueManager.submit(input:outputURL:preset:) async -> UUID
queueManager.submit(input:outputDirectory:preset:) async -> UUID
queueManager.cancel(jobID:)
queueManager.cancelAll()
queueManager.clearTerminal()

// JobModel —— 单行展示
job.id: UUID
job.inputURL / outputURL: URL
job.status: .pending/.running/.finished/.failed/.cancelled
job.progressFraction: Double    // 0...1
job.speedMultiplier: Double?   // e.g. 16.60×
job.wallClockSeconds: Double
job.inputBytes / outputBytes: Int64?
job.preset.name: String
job.errorMessage: String?
job.isActive / isTerminal: Bool（计算属性）
job.outputBytesFormatted: String（ByteCountFormatter.file）
```

---

## 文件结构

```
App/Sources/huaxing/
├── HuaXingMain.swift         # 已存在 —— @main + Scene 声明 + ContentView 占位 → 替换为 HuaXingRoot
├── Views/
│   ├── HuaXingRoot.swift     # NavigationSplitView 主体：侧栏 + 三 Tab 切换
│   ├── ConvertDropZone.swift # 主拖放区（.dropDestination）+ 预设选择 + 输出目录选择 + 开始按钮
│   ├── JobListView.swift     # Table 9 列 + 进度条 + 右键取消/重试/清空
│   ├── PresetEditorView.swift # Form —— add/edit/delete preset + kind-specific 子表单
│   ├── RuleEditorView.swift  # Form —— conditions builder（递归 all/any/not）+ action
│   ├── DiagnosticView.swift   # ScrollView List —— 8 条诊断 + 一键 refresh + brew 命令按钮
│   └── Components/
│       ├── StatusBadge.swift        # 作业状态颜色胶囊
│       ├── ProgressBar.swift        # 圆条或线性进度 + speed 文本
│       ├── MediaKindPicker.swift    # 视频/音频/图片分段选择
│       ├── PresetComboBox.swift     # 下拉选预设
│       └── ToolchainIndicator.swift # 全局顶部条 —— 🔴/🟡/🟢 工具链状态 + doctor 按钮
```

`HuaXingUI` 模型层文件不动，新视图全部放进 `Sources/huaxing/Views/`（属于 SwiftUI 可执行 target）。**视图层不新增任何 public 接口**，不需要改 HuaXingKit。

---

## 模块设计

### 1. HuaXingRoot.swift —— 主场景容器

```swift
NavigationSplitView {
    sidebar  // List —— 转换 / 作业 / 预设 / 规则 / 诊断
} content: {
    ToolchainIndicator()        // 顶部全局状态条
    Group {
        switch selectedTab {
        case .convert: ConvertDropZone()
        case .jobs:    JobListView()
        case .presets: PresetEditorView()
        case .rules:   RuleEditorView()
        case .diagnose: DiagnosticView()
        }
    }
    .frame(minWidth: 720, minHeight: 480)
} detail: {
    // 空 detail 栏 —— 内容全在 content 区（NavigationSplitView 三栏布局的简化版）
    EmptyView()
}
.navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
```

侧栏图标：`wand.and.stars` / `list.bullet.rectangle` / `slider.horizontal.3` / `list.clipboard` / `stethoscope`。

### 2. ConvertDropZone —— 拖放入队

```swift
VStack(spacing: 24) {
    // 大拖放区（Liquid Glass regular + 12pt 圆角）
    RoundedRectangle(cornerRadius: 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .frame(minHeight: 240)
        .overlay {
            VStack {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 56))
                Text("拖拽文件或文件夹到此处")
                    .font(.title2.weight(.semibold))
                Text("支持视频 / 音频 / 图片")
                    .foregroundStyle(.secondary)
            }
        }
        .dropDestination(for: URL.self) { urls, session in
            await queueDrop(urls)
            return true
        }
    
    // 预设 + 输出目录 + 开始按钮（水平行）
    HStack {
        PresetComboBox()      // 下拉 —— appModel.presets 过滤按 kind 匹配
        Spacer()
        OutputDirectoryPicker() // .fileImporter + 记住上次选择
        Button("开始转换") { ... }
            .buttonStyle(.borderedProminent)
    }
}
```

**核心交互**：拖入 → `dropDestination` async closure → 递归展开文件夹（`FileManager.enumerator`，同步，在 SwiftUI 主线程下可以但要 `.task` 或 `Task { @MainActor ... }` 桥接）→ 对每个 URL `await queueManager.submit(input:outputDirectory:preset:)` → 切到 `jobs` tab。

### 3. JobListView —— Table 9 列

```swift
Table(queueManager.jobs, selection: $selectedJobIDs) {
    TableColumn("名称")    { Text($0.inputURL.lastPathComponent) }
    TableColumn("状态")    { StatusBadge($0.status) }
    TableColumn("进度")    { ProgressBar(fraction: $0.progressFraction, speed: $0.speedMultiplier) }
    TableColumn("输入")    { ByteText($0.inputBytes) }
    TableColumn("输出")    { ByteText($0.outputBytes) }
    TableColumn("耗时")    { TimeText($0.wallClockSeconds) }
    TableColumn("预设")    { Text($0.preset.name) }
    TableColumn("规则")    { Text("—") /* 后续接入 RuleEngine */ }
    TableColumn("错误")    { Text($0.errorMessage ?? "").foregroundStyle(.red) }
}
.contextMenu(forSelectionType: UUID.self) { ids in
    Button("取消选中") { ids.forEach { queueManager.cancel(jobID: $0) } }
    Button("清除已完成") { queueManager.clearTerminal() }
}
```

**行数上限**：TableColumn 到 10 就会报错，这里 9 列留 1 列余量。**空状态**：`if jobs.isEmpty { EmptyStateView("还没有转换任务", icon: "tray") }`。

### 4. PresetEditorView —— Form 编辑器

左侧 List 列出所有 preset（`appModel.presets`），右侧 Form 编辑选中项。

```swift
NavigationSplitView {
    List(appModel.presets, selection: $selectedPresetID) { preset in
        VStack(alignment: .leading) {
            Text(preset.name).bold()
            Text(preset.kind.description).foregroundStyle(.secondary)
        }
    }
    Button("＋ 新建预设") { ... }
} detail: {
    if let preset = binding(for: selectedPresetID) {
        Form {
            TextField("名称", text: preset.name)
            Picker("类型", selection: preset.kind) { ... }
            Picker("容器", selection: preset.container) { ... }
            
            // video / audio / image 子表单 —— 按 kind 条件显示
            if preset.kind.wrappedValue == .video {
                VideoSettingsForm($preset.video)
            }
            ...
        }
        Button("保存") { appModel.updatePreset(preset.wrappedValue) }
        Button("删除", role: .destructive) { appModel.deletePreset(id: preset.id) }
    }
}
```

**关键**：`binding(for: String?) -> Binding<Preset>` 辅助函数从 `appModel.presets` 数组里按下标取出元素，双向绑定直接操作数组项。**不能用 ForEach + indices**（Swift 6 严格并发 + ObservableObject 的 Published 数组下标修改会触发问题）。

### 5. RuleEditorView —— 条件构建器

比 PresetEditor 复杂——conditions 是递归自引用的 `indirect enum RuleCondition`，UI 需要能 `all([any([...])])` 嵌套。

**简化策略**：先做**单层条件列表**（不递归嵌套 all/any/not），每一行一个条件类型的 form row。后续迭代再加深层嵌套。

```swift
// RuleEditorView —— v1 简化版
List {
    // 基本信息
    TextField("规则名称", text: $rule.name)
    Toggle("启用", isOn: $rule.enabled)
    Stepper("优先级", value: $rule.priority, in: 0...1000)
    
    Divider()
    
    // 条件（单层数组，无嵌套 all/any/not）
    Section("条件") {
        ForEach(rule.conditionsList) { cond in
            ConditionRow(condition: cond)  // 每个 cond 一行
        }
        Button("＋ 添加条件") { ... }
    }
    
    Divider()
    
    // Action
    Section("动作") {
        PresetPicker($rule.action.presetID)
        TextField("输出目录", text: $rule.action.outputDirectory)
        TextField("命名模板", text: $rule.action.naming)
        Picker("冲突策略", selection: $rule.action.collisionPolicy) { ... }
    }
}
```

**条件类型覆盖**（至少支持这些常用项）：
| Condition | 形式 | UI |
|---|---|---|
| `.mediaKind(is:)` | video/audio/image | 分段选择 |
| `.extension(in:)` | 数组 | TextField + Chip |
| `.resolution(minWidth:minHeight:)` | 可选 int | HStack Stepper |
| `.filenameGlob(pattern:)` | String | TextField |
| `.sourceDirectory(path:recursive:)` | String + Bool | TextField + Toggle |
| `.duration(minSeconds:maxSeconds:)` | 可选 Double | HStack Stepper |
| `.fileSize(minBytes:maxBytes:)` | 可选 Int64 | HStack Stepper + ByteUnitPicker |

**递归嵌套 all/any/not** 留 v2——那需要一个独立的 `ConditionTreeView` 组件 + drag-to-reorder，M10 不做。

### 6. DiagnosticView —— 诊断列表

最简单的视图。一行一条 diagnostic，severity 颜色区分。

```swift
ScrollView {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            Text("工具链诊断").font(.title2.weight(.semibold))
            Spacer()
            Button("重新探测") { Task { await appModel.refreshToolchain() } }
        }
        
        ForEach(appModel.diagnostics) { diag in
            HStack {
                severityIcon(diag.severity)  // SF Symbol + color
                VStack(alignment: .leading) {
                    Text(diag.tool.displayName).bold()
                    Text(diag.message).foregroundStyle(.secondary)
                }
                Spacer()
                if let cmd = diag.installCommand {
                    Button("修复建议") { copyToClipboard(cmd) }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
```

---

## 辅助组件

### StatusBadge

```swift
struct StatusBadge: View {
    let status: JobModel.Status
    var body: some View {
        let (color, icon, text) = switch status {
        case .pending:   (.gray,  "clock",          "等待中")
        case .running:   (.blue,  "progress.indicator", "运行中")
        case .finished:  (.green, "checkmark.circle",  "完成")
        case .failed:    (.red,   "xmark.circle",      "失败")
        case .cancelled: (.orange, "xmark",             "取消")
        }
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).font(.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
    }
}
```

### ProgressBar

视频/音频管线没有总时长 → 无法算精确 fraction，**仅靠 progressFraction 更新 done 标记** + speedMultiplier 显示。图片管线直接 0→1。

```swift
struct ProgressBar: View {
    let fraction: Double    // 0...1
    let speed: Double?       // e.g. 16.6 → "16.6×"
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: fraction)
            HStack {
                Text("\(Int(fraction * 100))%").font(.caption)
                Spacer()
                if let speed { Text(String(format: "%.1f×", speed)).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
```

### ToolchainIndicator

挂在 NavigationSplitView content 顶部的全局状态条。所有 diagnostic 都是 .ok 则绿色；有 warning 黄色；有 error 红色。

```swift
struct ToolchainIndicator: View {
    @EnvironmentObject var appModel: AppModel
    var body: some View {
        let allOk = appModel.diagnostics.allSatisfy { $0.severity == .ok }
        let hasError = appModel.diagnostics.contains { $0.severity == .error }
        
        HStack {
            Circle().fill(hasError ? .red : allOk ? .green : .yellow)
                .frame(width: 8, height: 8)
            Text(hasError ? "工具链异常" : allOk ? "全部就绪" : "有警告")
                .font(.caption)
            Spacer()
            Button("诊断…") { ... }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.quaternary)
    }
}
```

---

## HuaXingMain.swift 更新

把占位 ContentView 换成 HuaXingRoot，保持 @main + StateObject 初始化逻辑不变。**init() 里仍然只初始化模型和 queue，不起任何 GUI**——后续可扩展命令行模式（和 ntfyx `AppMode.parse` 同款）。

```swift
@main
struct HuaXingApp: App {
    @StateObject private var appModel: AppModel
    @StateObject private var queueManager: QueueManager
    
    init() {
        let model = AppModel()
        _appModel = StateObject(wrappedValue: model)
        _queueManager = StateObject(wrappedValue: QueueManager(
            appModel: model,
            pathProvider: { await model.toolchainSnapshot }
        ))
    }
    
    var body: some Scene {
        WindowGroup("化形") {
            HuaXingRoot()
                .environmentObject(appModel)
                .environmentObject(queueManager)
                .task { await appModel.load() }
        }
        .defaultSize(width: 1000, height: 640)
        
        Settings {
            SettingsView()  // v1 最小：只有 About / Bundle ID / Version 文本
        }
    }
}
```

---

## 实施顺序（建议 3-4 个 commit）

| # | 阶段 | 文件 | 验证 |
|---|------|------|------|
| 1 | 基础设施 + 主框架 | `Views/HuaXingRoot.swift`、`HuaXingMain.swift` 替换 ContentView | `make check-ui` 过；`swift build -c release` 过；打开 .app 看到侧栏 5 tab |
| 2 | Convert + Job | `Views/ConvertDropZone.swift`、`Views/JobListView.swift`、`Components/*` | 拖拽入队 → 切到 jobs tab → Table 9 列显示；真实转换跑起来；进度条动 |
| 3 | Preset + Rule | `Views/PresetEditorView.swift`、`Views/RuleEditorView.swift`（v1 单层） | 添加/编辑/保存 preset → JSON 落盘 → CLI `presets list` 读到 |
| 4 | Diagnostics + 收尾 | `Views/DiagnosticView.swift`、`HuaXingMain.swift` 加 Settings | toolchain 状态条实时刷新；doctor 按钮触发探测 |

每个阶段结束时 `make app` → `open .build/release/化形.app` 目视验证。

---

## 验收清单

**编译层（必过）**：
- [ ] `make check-ui` 无错误
- [ ] `swift build -c release -Xswiftc -disable-sandbox` App 子包 0 error（允许 warning）
- [ ] `make app` → 化形.app bundle 组装 + codesign 全过

**功能层（目视）**：
- [ ] 侧栏 5 tab 可切换，每个 tab 有内容（非空白）
- [ ] 拖放 mp4 → 入队 → 切到 jobs tab → 看到行 → 状态从 pending → running → finished
- [ ] 拖入文件夹 → 递归展开 → 多个 job 同时排队
- [ ] 真实 320×240 mp4 → HEVC 转换跑通，输出文件大小非零
- [ ] Preset 新建 → 填 Form → 保存 → `~Library/Application Support/im.yufei.huaxing/presets.json` 有新条目 → CLI `presets list` 读到
- [ ] Rule 新建（单层条件）→ 保存 → rules.json 有新条目
- [ ] Diagnostic 8 条 → 全绿；refresh 按钮触发后列表更新
- [ ] QueueManager maxConcurrent=2 → 拖 5 个文件 → 同时跑 2 个

**已知 v1 不做**（避免范围膨胀）：
- RuleCondition 递归嵌套 all/any/not 的 UI（v2）
- 进度条精确 fraction（视频/音频管线没传 duration，目前只有 done 标记 + speed 显示）
- 文件冲突 rename 策略的实际逻辑（GUI 层只传 preset.naming，CollisionPolicy 由 NamingTemplate.resolve 处理）
- Command 菜单（Cmd+, Settings / Cmd+Q Quit 等）
- Dock 图标自定义（先用默认 app 图标）
- 崩溃恢复（进程被杀后重启不恢复未完成 job）

---

## 风险与缓解

| 风险 | 概率 | 缓解 |
|---|---|---|
| Table 9 列宽不够 → 文字截断 | 中 | 每列设最小宽度；长字段（文件名、错误）wrap 或截断 + tooltip |
| ObservableObject + @Published 在大量 jobs 更新时 UI 卡 | 低 | QueueManager 内部 `jobs` 数组整体 replace（`jobs.append(job)` 会触发一次 UI 更新），不用 `jobs[i] = ...` 细粒度修改 |
| dropDestination 对文件夹递归 enumerate 阻塞主线程 | 中 | 先 `.task { }` 异步展开，或 `Task.detached` 跑 enumerator 再回主线程 append |
| HuaXingKit 模型层 API 变更导致视图编译失败 | 中 | 每次模型层改动同步更新 `docs/API_AUDIT.md`；M10 开始 HuaXingUI → HuaXingKit 的 API 视为"已冻结" |
| macOS 26 WindowGroup API 后续版本再变 | 低 | WindowGroup 比 Window 签名简单（只需 title），且是 Scene 级 API，不太可能再大改 |
