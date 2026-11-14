import Foundation
import Combine
import HuaXingKit

// MARK: - UIRuntimeState

/// 持有所有 UI 局部状态的 ObservableObject。
///
/// **设计原因**：CLT 缺 `libSwiftUIMacros` 插件 → `@State` / `@Binding` / `@AppStorage`
/// / `#Preview` 全部不可用（都是 SwiftUI 5 引入的 external macro）。
/// 统一走 `ObservableObject + @Published`（Combine property wrapper，无宏依赖）。
/// 每个视图从 `@EnvironmentObject var uiState: UIRuntimeState` 读写。
@MainActor
public final class UIRuntimeState: ObservableObject {

    // MARK: - Root tab

    @Published public var selectedTab: TabID = .convert

    public enum TabID: String, CaseIterable, Sendable {
        case convert, jobs, presets, rules, diagnose
    }

    // MARK: - ConvertDropZone

    @Published public var convertPresetID: String?
    @Published public var outputDirectory: URL?
    @Published public var isProcessingDrop: Bool = false
    @Published public var lastError: String?
    /// 最近一次拖放的入队结果，用于说明规则命中/跳过情况。
    @Published public var lastDropSummary: String?
    /// 拖放时是否先用规则引擎匹配；未命中再回退到手动预设。
    @Published public var useRulesForDrop: Bool = true

    // MARK: - JobListView

    @Published public var selectedJobIDs: Set<UUID> = []

    // MARK: - PresetEditorView

    @Published public var editorSelectedPresetID: String?

    // MARK: - RuleEditorView

    @Published public var selectedRuleID: String?

    // MARK: - OutputDirectoryPicker

    @Published public var showDirectoryPicker: Bool = false
    @Published public var showFilePicker: Bool = false

    public init() {}
}
