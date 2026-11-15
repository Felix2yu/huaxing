import SwiftUI
import HuaXingUI

@main
struct HuaXingApp: App {
    @StateObject private var appModel: AppModel
    @StateObject private var queueManager: QueueManager
    @StateObject private var uiState: UIRuntimeState

    init() {
        let model = AppModel()
        _appModel = StateObject(wrappedValue: model)
        _queueManager = StateObject(wrappedValue: QueueManager(
            appModel: model,
            pathProvider: { model.toolchainSnapshot }
        ))
        _uiState = StateObject(wrappedValue: UIRuntimeState())
    }

    var body: some Scene {
        WindowGroup("化形") {
            HuaXingRoot()
                .environmentObject(appModel)
                .environmentObject(queueManager)
                .environmentObject(uiState)
                .task { await appModel.load() }
        }
        .defaultSize(width: 1000, height: 640)

        Settings {
            SettingsView()
        }
    }
}
