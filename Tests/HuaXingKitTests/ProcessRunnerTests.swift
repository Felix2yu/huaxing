import Foundation
import Testing
@testable import HuaXingKit

struct ProcessRunnerTests {

    @Test("run captures stdout and stderr")
    func runCapturesOutput() async throws {
        let spec = ProcessSpec(
            executable: "/bin/echo",
            arguments: ["hello"]
        )
        let result = await ProcessRunner.run(spec)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("hello"))
        #expect(result.launched)
    }

    @Test("run detects non-zero exit")
    func runDetectsNonZero() async throws {
        let spec = ProcessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "echo err_msg >&2; exit 42"]
        )
        let result = await ProcessRunner.run(spec)
        #expect(result.exitCode == 42)
        #expect(result.stderr.contains("err_msg"))
    }

    @Test("run fails gracefully on missing executable")
    func runMissingExecutable() async throws {
        let spec = ProcessSpec(
            executable: "/nonexistent/binary/path"
        )
        let result = await ProcessRunner.run(spec)
        #expect(!result.launched)
        #expect(result.exitCode == -1)
    }

    @Test("lines streams output line by line and can be cancelled")
    func linesCanBeCancelled() async throws {
        let spec = ProcessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "for i in $(seq 100); do echo line_$i; sleep 0.1; done"]
        )
        let (stream, handle) = ProcessRunner.lines(spec)

        var count = 0
        for await _ in stream {
            count += 1
            if count >= 3 {
                handle.cancel()
                break
            }
        }
        #expect(count >= 3)
        // Give the cancel a moment to propagate
        try await Task.sleep(nanoseconds: 500_000_000)
        // Process should have been killed
        #expect(!isProcessStillRunning(spec))
    }

    private func isProcessStillRunning(_ spec: ProcessSpec) -> Bool {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid,command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        // Drain the pipe *before* waiting: `ps -axo` can emit more than the
        // 64 KB pipe buffer, and a blocked child would never exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("for i in")
    }
}
