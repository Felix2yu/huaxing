import Foundation
import HuaXingKit

@main
struct HuaxingctlMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let code = await dispatch(args)
        exit(code)
    }
}

// MARK: - Helpers

extension Array {
    /// Runs an async transformation over each element and collects results in order.
    func asyncMap<U>(_ transform: @Sendable (Element) async -> U) async -> [U] {
        var result: [U] = []
        result.reserveCapacity(count)
        for item in self { result.append(await transform(item)) }
        return result
    }
}
