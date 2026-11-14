import Foundation
import Testing
@testable import HuaXingKit

struct ToolchainTests {

    @Test("ToolVersion.parse handles various output formats")
    func parsesVersions() {
        #expect(ToolVersion.parse("ffmpeg version 9.0.2 Copyright") == ToolVersion(9, 0, 2))
        #expect(ToolVersion.parse("version 6.4") == ToolVersion(6, 4, 0))
        #expect(ToolVersion.parse("cjxl v0.12.0 0.12.0 [_NEON_BF16_]") == ToolVersion(0, 12, 0))
        #expect(ToolVersion.parse("no number here") == nil)
    }

    @Test("ToolVersion comparison is total order")
    func versionCompare() {
        #expect(ToolVersion(6, 0, 0) < ToolVersion(7, 0, 0))
        #expect(ToolVersion(9, 0, 1) > ToolVersion(9, 0, 0))
        #expect(ToolVersion(0, 12, 0) >= ToolVersion(0, 10, 0))
    }

    @Test("ToolLocator resolves expected tools on this machine")
    func locatesAllExpected() {
        for tool in [Tool.ffmpeg, .cjxl, .sips] {
            let path = ToolLocator.resolve(tool)
            #expect(path != nil, "ToolLocator should find \(tool.rawValue) on this machine")
        }
    }
}
