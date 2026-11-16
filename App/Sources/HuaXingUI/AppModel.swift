import Foundation
import Combine
import HuaXingKit

// MARK: - AppModel

/// 顶层应用状态模型。持有所有持久化数据和工具链快照，
/// 通过 Combine 的 ObservableObject 协议让 SwiftUI 视图订阅变化。
///
/// 全部 @Published 属性都是 Sendable 的值类型（Preset / Rule / Diagnostic /
/// ToolchainSnapshot），可以在 Swift 6 严格并发下安全跨 actor 边界传递。
///
/// App target 启用 Swift 6.2 默认 MainActor 隔离，这里不再重复标注 `@MainActor`。
public final class AppModel: ObservableObject {

    // MARK: - Published state

    @Published public var presets: [Preset] = []
    @Published public var rules: [Rule] = []
    @Published public var diagnostics: [Diagnostic] = []
    @Published public var toolchainSnapshot: ToolchainSnapshot?
    /// 探测进行中标记，供状态条 / 诊断页给出可见反馈并防止重复触发。
    @Published public private(set) var isRefreshingToolchain = false
    /// 最近一次探测完成时间 —— 让「重新探测」在结果不变时也有可见反馈。
    @Published public private(set) var lastToolchainCheck: Date?

    // MARK: - Stores

    public let presetStore = PresetStore()
    public let ruleStore = RuleStore()
    // Toolchain actor 不持久持有 —— 每次 refresh 时新建，避免 MainActor ↔ actor 隔离问题。

    public init() {}

    // MARK: - Lifecycle

    /// 应用启动时调用 —— 从磁盘加载 presets/rules 并探测工具链。
    public func load() async {
        await AppPaths.ensureDirectoryOrLog()

        // 加载 preset + rules —— 同步 API，不跨 actor
        do {
            presets = try presetStore.load()
        } catch {
            Log.error("AppModel: failed to load presets: \(error)")
            presets = []
        }

        do {
            rules = try ruleStore.load()
        } catch {
            Log.error("AppModel: failed to load rules: \(error)")
            rules = []
        }

        // 工具链探测 —— actor，await
        await refreshToolchain()
    }

    /// 重新探测工具链（用户手动触发或收到外部通知时）。
    ///
    /// 每次都新建 Toolchain，不复用缓存快照，因此安装/修复工具后点「重新探测」
    /// 能立刻反映最新状态。`isRefreshingToolchain` 让 UI 有可见的进行中反馈，
    /// 同时避免并发探测互相覆盖 diagnostics。
    public func refreshToolchain() async {
        guard !isRefreshingToolchain else { return }
        isRefreshingToolchain = true
        defer { isRefreshingToolchain = false }

        let tc = Toolchain()
        let snap = await tc.snapshot()
        toolchainSnapshot = snap
        diagnostics = Doctor.diagnose(snapshot: snap)
        lastToolchainCheck = Date()
    }

    // MARK: - Preset CRUD

    public func addPreset(_ preset: Preset) {
        presets.append(preset)
        persistPresets()
    }

    public func updatePreset(_ preset: Preset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            persistPresets()
        }
    }

    public func deletePreset(id: String) {
        presets.removeAll { $0.id == id }
        persistPresets()
    }

    // MARK: - Rule CRUD

    public func addRule(_ rule: Rule) {
        rules.append(rule)
        persistRules()
    }

    public func updateRule(_ rule: Rule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
            persistRules()
        }
    }

    public func deleteRule(id: String) {
        rules.removeAll { $0.id == id }
        persistRules()
    }

    public func toggleRule(id: String) {
        if let idx = rules.firstIndex(where: { $0.id == id }) {
            rules[idx].toggleEnabled()
            persistRules()
        }
    }

    private func persistPresets() {
        do { try presetStore.save(presets) }
        catch { Log.error("AppModel: failed to save presets: \(error)") }
    }

    private func persistRules() {
        do { try ruleStore.save(rules) }
        catch { Log.error("AppModel: failed to save rules: \(error)") }
    }

    // MARK: - Toolchain access

    /// 获取 ffmpeg 路径（工具链已探测的前提下）。
    public var ffmpegPath: String? {
        guard case .success(let r) = toolchainSnapshot?.tools[.ffmpeg] else { return nil }
        return r.path
    }

    public var cjxlPath: String? {
        guard case .success(let r) = toolchainSnapshot?.tools[.cjxl] else { return nil }
        return r.path
    }

    public var cwebpPath: String? {
        guard case .success(let r) = toolchainSnapshot?.tools[.cwebp] else { return nil }
        return r.path
    }
}

// MARK: - Helpers

private extension AppPaths {
    static func ensureDirectoryOrLog() async {
        do {
            try AppPaths.ensureDirectory()
        } catch {
            Log.error("AppPaths: failed to create support dir: \(error)")
        }
    }
}

private extension Rule {
    mutating func toggleEnabled() { enabled.toggle() }
}
