import SwiftUI
import HuaXingKit
import HuaXingUI

// MARK: - HuaXingRoot

/// 主场景容器：NavigationSplitView —— 侧栏 tab + content 区。
struct HuaXingRoot: View {
    @EnvironmentObject var appModel: AppModel
    @EnvironmentObject var uiState: UIRuntimeState

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            contentArea
                .frame(minWidth: 720, minHeight: 480)
        } detail: {
            EmptyView()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 280)
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { uiState.selectedTab },
            set: { uiState.selectedTab = $0 ?? .convert }
        )) {
            ForEach(UIRuntimeState.TabID.allCases, id: \.self) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var contentArea: some View {
        VStack(spacing: 0) {
            ToolchainIndicator()
            Divider()
            Group {
                switch uiState.selectedTab {
                case .convert:  ConvertDropZone()
                case .jobs:     JobListView()
                case .presets:  PresetEditorView()
                case .rules:    RuleEditorView()
                case .diagnose: DiagnosticView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Tab helpers

extension UIRuntimeState.TabID {
    var title: String {
        switch self {
        case .convert: return "转换"
        case .jobs:    return "作业"
        case .presets: return "预设"
        case .rules:   return "规则"
        case .diagnose: return "诊断"
        }
    }
    var icon: String {
        switch self {
        case .convert: return "wand.and.stars"
        case .jobs:    return "list.bullet.rectangle.portrait"
        case .presets: return "slider.horizontal.3"
        case .rules:   return "list.clipboard"
        case .diagnose: return "stethoscope"
        }
    }
}

// MARK: - SettingsView

/// v1 简化版 Settings：只显示基本信息。
struct SettingsView: View {
    var body: some View {
        Form {
            Section("关于") {
                LabeledContent("Bundle ID", value: "im.yufei.huaxing")
                LabeledContent("最低系统版本", value: "macOS 27.0")
            }
            Section("命令行") {
                Text("CLI 随 .app 打包，位于 Contents/MacOS/huaxingctl")
                    .font(.caption).foregroundStyle(.secondary)
                Text("可软链到 /usr/local/bin")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

// MARK: - ToolchainIndicator

/// 全局顶部状态条 —— 所有 diagnostic 绿色则全绿。
struct ToolchainIndicator: View {
    @EnvironmentObject var appModel: AppModel
    @EnvironmentObject var uiState: UIRuntimeState

    var body: some View {
        HStack(spacing: 8) {
            // 固定 12×12 容器：探测中与常态两种图标占位一致，状态条不跳动。
            Group {
                if appModel.isRefreshingToolchain {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 12, height: 12)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // 「诊断…」按 macOS 惯例应打开诊断界面，而不只是静默重跑探测；
            // 同时切页能让「重新探测」的结果与进度立刻可见。
            Button("诊断…") {
                uiState.selectedTab = .diagnose
                Task { await appModel.refreshToolchain() }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .disabled(appModel.isRefreshingToolchain)
            .help("打开诊断页并重新检测工具链")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
    }

    /// 与 CLI doctor 共用一套判定：只有 .error（必需工具）才标红。
    private var health: DiagnosticSummary {
        Doctor.summary(appModel.diagnostics)
    }
    private var statusColor: Color {
        if health.errors > 0 { return .red }
        if health.warnings > 0 { return .orange }
        return .green
    }
    private var statusText: String {
        if appModel.isRefreshingToolchain { return "正在检测工具链…" }
        if appModel.diagnostics.isEmpty { return "加载诊断中…" }
        if health.errors > 0 { return "工具链异常（\(health.errors) 项错误）" }
        if health.warnings > 0 { return "有 \(health.warnings) 项可选工具警告" }
        return "全部就绪"
    }
}
