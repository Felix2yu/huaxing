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

    /// Regression: GUI apps launched by LaunchServices get a minimal PATH that
    /// omits Homebrew. The hardcoded fallback directories must still resolve.
    @Test("ToolLocator works with a GUI-minimal PATH")
    func resolvesWithMinimalPATH() {
        let minimal = "/usr/bin:/bin:/usr/sbin:/sbin"

        // sips always exists on macOS and lives in a hardcoded candidate dir.
        let sips = ToolLocator.resolve(.sips, pathEnvironment: minimal)
        #expect(sips == "/usr/bin/sips")

        // An empty PATH must not disable the fallback either.
        #expect(ToolLocator.resolve(.sips, pathEnvironment: "") == "/usr/bin/sips")
    }

    @Test("ToolLocator finds Homebrew ffmpeg when PATH omits /opt/homebrew/bin")
    func resolvesHomebrewWithoutPATH() {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else {
            return // Homebrew not installed on this machine
        }
        let found = ToolLocator.resolve(.ffmpeg, pathEnvironment: "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(found == "/opt/homebrew/bin/ffmpeg")
    }

    @Test("userOverride wins over directory lookup")
    func overrideTakesPrecedence() {
        let found = ToolLocator.resolve(
            .sips,
            userOverride: "/usr/bin/sips",
            pathEnvironment: ""
        )
        #expect(found == "/usr/bin/sips")
    }
}
