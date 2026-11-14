import SwiftUI

struct Probe: App {
    @State private var count = 0
    var body: some Scene {
        WindowGroup("p") {
            Text("count: \(count)")
            Button("increment") { count += 1 }
        }
    }
}
