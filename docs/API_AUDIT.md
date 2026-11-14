# API Audit — HuaXingUI → HuaXingKit

SwiftUI 层（`App/Sources/HuaXingUI/*.swift`）调用 HuaXingKit API 的完整签名核对表。
每次 HuaXingKit API 变更时需更新此表，确保调用方签名与实际一致。

---

## AppModel.swift

### PresetStore
| API | Signature | 状态 |
|-----|-----------|------|
| `PresetStore.init(url:)` | `public init(url: URL = AppPaths.presetsFile)` | ✅ |
| `PresetStore.load()` | `public func load() throws -> [Preset]` | ✅ |
| `PresetStore.save(_:)` | `public func save(_ presets: [Preset]) throws` | ✅ |

### RuleStore
| API | Signature | 状态 |
|-----|-----------|------|
| `RuleStore.init(url:)` | `public init(url: URL = AppPaths.rulesFile)` | ✅ |
| `RuleStore.load()` | `public func load() throws -> [Rule]` | ✅ |
| `RuleStore.save(_:)` | `public func save(_ rules: [Rule]) throws` | ✅ |

### Toolchain
| API | Signature | 状态 |
|-----|-----------|------|
| `Toolchain.init(userOverrides:)` | `public init(userOverrides: [Tool: String] = [:])` | ✅ |
| `Toolchain.snapshot()` | `public func snapshot() async -> ToolchainSnapshot` | ✅ |

### Doctor
| API | Signature | 状态 |
|-----|-----------|------|
| `Doctor.diagnose()` | `public static func diagnose() async -> [Diagnostic]` | ✅ |
| `Doctor.diagnose(snapshot:)` | `public static func diagnose(snapshot: ToolchainSnapshot) -> [Diagnostic]` | ✅ |
| `Doctor.summary(_:)` | `public static func summary(_ diagnostics: [Diagnostic]) -> DiagnosticSummary` | ✅ |
| `Doctor.hasError(_:)` | `public static func hasError(_ diagnostics: [Diagnostic]) -> Bool` | ✅ |
| `Tool.isRequired` | `public var isRequired: Bool`（仅 ffmpeg/ffprobe） | ✅ |
| `DiagnosticSummary` | `errors` / `warnings` / `ok`（`ok == errors == 0`） | ✅ |

严重级别约定：必需工具（ffmpeg/ffprobe）缺失、损坏、版本过低 → `.error`；可选工具
（djxl/dwebp/jxlinfo/sips）→ `.warning`。CLI `doctor` 与 `ToolchainIndicator` 都复用
`Doctor.summary`，只有 `.error` 才让退出码变为 2 / 顶部状态变红。

### AppPaths
| API | Signature | 状态 |
|-----|-----------|------|
| `AppPaths.ensureDirectory()` | `public static func ensureDirectory() throws` | ✅ |

### ToolchainSnapshot (只读)
| API | Signature | 状态 |
|-----|-----------|------|
| `.tools` | `public var tools: [Tool: Result<ToolResolution, ToolFailure>]` | ✅ |
| `subscript(_:)` | `public subscript(_ tool: Tool) -> Result<ToolResolution, ToolFailure>?` | ✅ |

### Preset 值类型
| 字段 | 类型 | 状态 |
|------|------|------|
| `Preset.id` | `String` | ✅ |
| `Preset.name` | `String` | ✅ |
| `Preset.kind` | `MediaInfo.Kind` | ✅ |
| `Preset.container` | `Container` | ✅ |
| `Preset.video` | `VideoSettings?` | ✅ |
| `Preset.audio` | `AudioSettings?` | ✅ |
| `Preset.image` | `ImageSettings?` | ✅ |
| `Preset.naming` | `String`（默认 `{name}`） | ✅ |
| `Preset.outputDirectory` | `String`（默认 `~/Desktop`） | ✅ |
| `Preset.keepMetadata` | `Bool` | ✅ |
| `Preset.outputExtension` | `String`（计算属性） | ✅ |

输出目录优先级：CLI `--out` > 规则 `rule.action.outputDirectory` > 预设
`preset.outputDirectory` > `~/huaxing-out`（仅 CLI 无预设时）。空字符串会被
`RuleExecutor.firstNonEmpty` 回退，绝不会落到进程当前工作目录。

### Rule 值类型
| 字段 | 类型 | 状态 |
|------|------|------|
| `Rule.id` | `String` | ✅ |
| `Rule.name` | `String` | ✅ |
| `Rule.enabled` | `Bool` | ✅ |
| `Rule.priority` | `Int` | ✅ |

---

## JobModel.swift

### ConversionResult
| API | Signature | 状态 |
|-----|-----------|------|
| `inputURL` | `public var inputURL: URL` | ✅ |
| `outputURL` | `public var outputURL: URL` | ✅ |
| `inputBytes` | `public var inputBytes: Int64?` | ✅ |
| `outputBytes` | `public var outputBytes: Int64?` | ✅ |
| `wallClockSeconds` | `public var wallClockSeconds: Double` | ✅ |

### ImagePipeline.ImageConversionResult
| API | Signature | 状态 |
|-----|-----------|------|
| `outputURL` | `public var outputURL: URL` | ✅ |
| `outputBytes` | `public var outputBytes: Int64?` | ✅ |
| `metadataLost` | `public var metadataLost: Bool` | ✅ |
| `wallClockSeconds` | `public var wallClockSeconds: Double` | ✅ |

### FFmpegProgress (间接 — QueueManager.progress 回调中使用)
| API | 类型 | 状态 |
|-----|------|------|
| `prog.speed` | `Double?` | ✅ |
| `prog.done` | `Bool` | ✅ |

---

## QueueManager.swift

### VideoPipeline
| API | Signature | 状态 |
|-----|-----------|------|
| `VideoPipeline.init(ffmpegPath:)` | `public init(ffmpegPath: String)` | ✅ |
| `VideoPipeline.run(input:output:preset:progress:onStart:)` | `public func run(input: URL, output: URL, preset: Preset, progress: @Sendable (FFmpegProgress) -> Void = { _ in }, onStart: (@Sendable (ProcessHandle) -> Void)? = nil) async throws -> ConversionResult` | ✅ |

### AudioPipeline
| API | Signature | 状态 |
|-----|-----------|------|
| `AudioPipeline.init(ffmpegPath:)` | `public init(ffmpegPath: String)` | ✅ |
| `AudioPipeline.run(input:output:preset:progress:onStart:)` | `public func run(input: URL, output: URL, preset: Preset, progress: @Sendable (FFmpegProgress) -> Void = { _ in }, onStart: (@Sendable (ProcessHandle) -> Void)? = nil) async throws -> ConversionResult` | ✅ |

### ImagePipeline
| API | Signature | 状态 |
|-----|-----------|------|
| `ImagePipeline.init(toolchain:)` | `public init(toolchain: ToolchainSnapshot)` | ✅ |
| `ImagePipeline.run(input:output:target:)` | `public func run(input: URL, output: URL, target: ImageTarget) async throws -> ImageConversionResult` | ✅ |
| `ImagePipeline.run(input:output:settings:keepMetadata:)` | `public func run(input: URL, output: URL, settings: ImageSettings, keepMetadata: Bool = true) async throws -> ImageConversionResult` | ✅ |

### NamingTemplate
| API | Signature | 状态 |
|-----|-----------|------|
| `NamingTemplate.init(_:)` | `public init(_ template: String = "{name}")` | ✅ |
| `NamingTemplate.render(_:)` | `public func render(_ ctx: NamingContext) -> String` | ✅ |

### NamingContext
| API | Signature | 状态 |
|-----|-----------|------|
| `NamingContext.init(name:ext:width:height:duration:codec:preset:index:)` | 所有参数均有默认值 | ✅ |

### Container (私有扩展使用)
| API | 类型 | 状态 |
|-----|------|------|
| `Container.allCases` | `[Container]` | ✅ (CaseIterable) |

### ImageTarget (私有扩展使用)
| API | 类型 | 状态 |
|-----|------|------|
| `ImageTarget.allCases` | `[ImageTarget]` | ✅ (CaseIterable) |

### RuleExecutor（GUI 与 CLI 共用）
| API | Signature | 状态 |
|-----|-----------|------|
| `RuleExecutor.makePlan(input:mediaInfo:rule:preset:occupied:)` | `public static func makePlan(...) throws -> RuleExecutionPlan` | ✅ |
| `RuleExecutor.performPostProcessing(_:output:source:)` | `public static func performPostProcessing([PostProcessStep], output: URL, source: URL) async` | ✅ |
| `RuleExecutionPlan` | `ruleID/ruleName/presetID/outputURL/keepMetadata/collisionPolicy/postProcessing` | ✅ |
| `RuleInput.sourceDirectory` | `String?`（规则条件 `.sourceDirectory` 使用） | ✅ |
| `RuleAction.postProcessing` | `[PostProcessStep]`（GUI 三个开关可编辑） | ✅ |
| `QueueManager.submit(input:fallbackPreset:fallbackDirectory:rules:presets:)` | `async throws -> UUID?`；`.skip` 命中返回 nil | ✅ |

规则命中后由 `makePlan` 统一决定：预设、输出目录、命名模板、冲突策略
（overwrite / rename / skip）、`keepMetadata` 与后处理；GUI 的 `JobModel` 携带
`ruleName` / `postProcessing` / `keepMetadata`，任务成功后由 `runJob` 执行后处理。
CLI `rules run` 复用同一函数，因此两个前端行为一致。

---

## Error Types

| Type | 协议 | UI 层处理方式 | 状态 |
|------|------|--------------|------|
| `ConversionError` | `Error, Sendable, LocalizedError` | `error.localizedDescription` | ✅ |
| `ImageError` | `Error, Sendable, LocalizedError` | `error.localizedDescription` | ✅ |
| `ToolchainError` | `Error, Sendable` | `error.localizedDescription` | ✅ |
| `PersistenceError` | `Error, Sendable` | `catch` + Log.error | ✅ |
| `RuleExecutionError` | `Error, Sendable, LocalizedError` | `.skip` 命中时由调用方转成"已跳过" | ✅ |
| `QueueError` | `Error, Sendable, LocalizedError` | 拖放入队失败时显示在错误行 | ✅ |

---

## Sendability Audit

HuaXingUI 所有 @Published 属性持有的值 **必须是 Sendable**：

| HuaXingKit 类型 | Sendable | 来源 |
|-----------------|----------|------|
| `Preset` | ✅ | `Sendable, Codable, Identifiable, Equatable` |
| `Rule` | ✅ | `Sendable, Codable, Identifiable, Equatable` |
| `Diagnostic` | ✅ | `Sendable, Equatable` |
| `ToolchainSnapshot` | ✅ | `Sendable` |
| `ConversionResult` | ✅ | `Sendable, Equatable` |
| `ImageConversionResult` | ✅ | `Sendable, Equatable` |

HuaXingUI 类型自身：
| 类型 | 隔离 | Sendable 策略 |
|------|------|---------------|
| `AppModel` | `@MainActor` | 主线程隔离不需要 Sendable |
| `JobModel` | `@MainActor` | 同上 |
| `QueueManager` | `@MainActor` | 同上 |

---

## 已知限制 & 后续迭代

1. ~~**QueueManager.progressFraction** — 视频/音频管线没有总时长参数~~ 已解决：`QueueManager.runJob` 入队后先 ffprobe 一次，进度改用 `outTimeMicroseconds / duration` 计算。
2. **Toolchain actor 不复用** — AppModel 每次 refreshToolchain 都新建 Toolchain 实例，因为 @MainActor 不能持久持有 actor。影响极小（snapshot 只需几百 ms）。
3. ~~**NamingContext 不探测 MediaInfo**~~ 已解决：`QueueManager.submit` 与 CLI `convert` / `rules run` 在生成输出路径前都先 ffprobe，`{width}/{height}/{duration}/{codec}` 均可渲染。
4. **JXL/WebP 的 `metadataLost` 仍以"是否走了 PNG 中间图"为准** — 直接可读输入（PNG/JPEG 等）由 cjxl/cwebp 读取原图，cwebp 显式传 `-metadata all`，不再报丢失；缩放或不支持的输入格式走中间图时仍如实报告丢失（`ImageIOBridge.hasPreservableMetadata` 只在源图确有 EXIF/XMP/GPS/IPTC 时为真，不再把基础像素属性误当元数据）。

---

## 功能闭环核对（2026-11-14）

| # | 问题 | 落点 |
|---|------|------|
| 1 | GUI 拖放未接入规则引擎 | `ConvertDropZone.queueDrop` → `QueueManager.submit(...rules:presets:)`；作业表显示命中规则名 |
| 2 | `rules run` 只匹配不转换 | `runRulesRun` → `makePlan` → `performConversion` → 后处理；`--dry-run` 仅出计划，`--rule` 可省略 |
| 3 | `collisionPolicy` 未生效 | GUI/CLI 共用 `makePlan`；overwrite 复用原路径、rename 追加 `-N`、skip 抛错并计入 `skipped` |
| 4 | `postProcessing` 无执行入口 | `RuleExecutor.performPostProcessing`；GUI `runJob` 成功后执行，CLI 转换成功后执行；规则编辑器三个开关 |
| 5 | 输出目录被忽略 | 规则 `action.outputDirectory`、预设 `outputDirectory`、CLI `--out` 三级优先；空值回退到预设 |
| 6 | Doctor 可选工具误报 | `.isRequired` + `Doctor.summary`；可选工具为 `.warning`，仅 error 影响退出码与顶部状态 |
| 7 | GUI 命名模板宽高时长为空 | `QueueManager.probeInfo` 在入队前 ffprobe |
| 8 | CLI 图片转换强依赖 ffmpeg | `runConvert` 只要求 ffprobe；`performConversion` 仅在视频/音频分支要求 ffmpeg；图片预设的 `toolsNeeded` 不含 ffmpeg/ffprobe |
| 9 | JXL/WebP 恒报元数据丢失 | `ImageIOBridge.hasPreservableMetadata` + 直接读原图分支；cwebp 传 `-metadata all` |

验证：根包 `swift build` / 41 个单测 / `make check-model` / App 子包 release 构建 /
`make app` 打包签名全部通过；CLI 20 项端到端断言 `ALL_PASS`；后处理执行探针确认
`trashSource` 真实移动源文件。`Makefile` 的 `SANDBOX` 与 `App/build-app.sh` 的两个
`swift build` 均增加 `--disable-sandbox`（SwiftPM manifest 层），与原有的
`-Xswiftc -disable-sandbox`（编译器层）配合，受限环境/CI 下 `make build/test/app/doctor`
才能全部跑通。
