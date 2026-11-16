import Foundation
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

// MARK: - ProcessSpec

/// One subprocess invocation: executable path + literal argv. No shell mode —
/// HuaXingKit always passes arguments directly to avoid injection surfaces.
public struct ProcessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?
    public var timeout: TimeInterval

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 300
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

/// The combined stdout/stderr buffers, exit code, and timeout flag from a run.
public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var launched: Bool
}

/// One line (or partial line) from either stream emitted by `ProcessRunner.lines`.
public struct OutputLine: Sendable {
    public enum Stream: Sendable { case stdout, stderr }
    public var stream: Stream
    public var text: String
}

// MARK: - Private helpers

/// Internal signal that the timeout elapsed. Not surfaced to callers; the
/// handle's `didTimeOut` flag communicates the outcome instead.
private enum ProcessRunnerError: Error { case timedOut }

extension TerminationStatus {
    /// The raw exit/signal code, normalized to `Int32`.
    var exitCode: Int32 {
        switch self {
        case .exited(let code): code
        case .signaled(let code): code
        }
    }
}

// MARK: - ProcessHandle

/// Handle returned by `ProcessRunner.lines`; call `cancel()` to terminate the
/// subprocess. `waitUntilExit()` blocks until the subprocess exits and returns
/// its exit code, matching the `Foundation.Process`-based contract it replaces.
public final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var didCancel = false
    private var timedOut = false
    private var exitCode: Int32?
    private var task: Task<Void, Never>?
    private let exitGroup = DispatchGroup()

    init() {
        exitGroup.enter()
    }

    /// Wire up the underlying task so `cancel()` can tear it down.
    fileprivate func attach(_ task: Task<Void, Never>) {
        lock.lock(); self.task = task; lock.unlock()
    }

    /// Record the subprocess exit code and unblock any `waitUntilExit()` waiter.
    fileprivate func recordExit(_ code: Int32) {
        lock.lock(); if exitCode == nil { exitCode = code }; lock.unlock()
        exitGroup.leave()
    }

    /// Mark the run as timed out (used by the watchdog race).
    fileprivate func markTimedOut() {
        lock.lock(); timedOut = true; lock.unlock()
    }

    public var isLaunched: Bool { true }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return didCancel
    }

    public var didTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }; return timedOut
    }

    /// Blocks until the subprocess exits and returns its termination status.
    /// Returns -1 when the process was never launched or the spawn failed.
    @discardableResult
    public func waitUntilExit() -> Int32 {
        exitGroup.wait()
        lock.lock(); let code = exitCode ?? -1; lock.unlock()
        return code
    }

    public func cancel() {
        lock.lock()
        guard !didCancel else { lock.unlock(); return }
        didCancel = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

// MARK: - ProcessRunner

public enum ProcessRunner {
    public static let enhancedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Build a Subprocess `Environment` from the spec: inherit the parent
    /// environment, override PATH with the enhanced search path, then merge any
    /// caller-provided extras (PATH excluded — it's already fully overridden).
    static func environment(extra: [String: String]?) -> Environment {
        var overrides: [Environment.Key: String?] = ["PATH": enhancedPATH]
        if let extra {
            for (k, v) in extra where k != "PATH" {
                overrides[Environment.Key(stringLiteral: k)] = v
            }
        }
        return .inherit.updating(overrides)
    }

    /// Full-buffered run — returns exit code + both stream strings.
    ///
    /// Implemented on top of Subprocess 1.0: `run(...)` collects stdout/stderr
    /// and returns a non-zero exit code as a normal result (not a thrown error).
    @concurrent
    public static func run(_ spec: ProcessSpec) async -> ProcessResult {
        do {
            let result = try await Subprocess.run(
                .path(FilePath(spec.executable)),
                arguments: Arguments(spec.arguments),
                environment: environment(extra: spec.environment),
                output: .string(limit: Int.max),
                error: .string(limit: Int.max)
            )
            return ProcessResult(
                exitCode: result.terminationStatus.exitCode,
                stdout: result.standardOutput,
                stderr: result.standardError,
                timedOut: false,
                launched: true
            )
        } catch {
            return ProcessResult(
                exitCode: -1, stdout: "",
                stderr: "Failed to execute: \(error.localizedDescription)",
                timedOut: false, launched: false
            )
        }
    }

    /// Line-streaming variant — yields each line as an `OutputLine` on the
    /// returned `AsyncStream`. Cancelling the returned `ProcessHandle`
    /// terminates the subprocess, and the stream ends once the process exits.
    ///
    /// Implemented on top of Subprocess 1.0: the body closure receives the
    /// running subprocess's stdout/stderr as `AsyncSequence`s; cancelling the
    /// enclosing task makes Subprocess tear down the child automatically.
    public static func lines(_ spec: ProcessSpec) -> (AsyncStream<OutputLine>, ProcessHandle) {
        let (stream, continuation) = AsyncStream.makeStream(of: OutputLine.self)
        let handle = ProcessHandle()

        let task = Task(name: "ProcessRunner.lines") { @Sendable in
            var code: Int32 = -1
            do {
                code = try await withThrowingTaskGroup { group in
                    group.addTask {
                        let result = try await Subprocess.run(
                            .path(FilePath(spec.executable)),
                            arguments: Arguments(spec.arguments),
                            environment: Self.environment(extra: spec.environment),
                            input: .none,
                            output: .sequence,
                            error: .sequence
                        ) { execution in
                            async let out = collect(execution.standardOutput, stream: .stdout, into: continuation)
                            async let err = collect(execution.standardError, stream: .stderr, into: continuation)
                            _ = await (out, err)
                        }
                        return result.terminationStatus.exitCode
                    }
                    if spec.timeout.isFinite, spec.timeout > 0 {
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(spec.timeout * 1_000_000_000))
                            handle.markTimedOut()
                            throw ProcessRunnerError.timedOut
                        }
                    }
                    let first = try await group.next()
                    group.cancelAll()
                    return first ?? -1
                }
            } catch {
                if !(error is CancellationError), !handle.didTimeOut {
                    continuation.yield(.init(stream: .stderr, text: "Failed to execute: \(error.localizedDescription)"))
                }
            }
            // Cleanup runs on the normal and cancelled paths alike: when
            // `handle.cancel()` cancels the enclosing task, `Subprocess.run`
            // throws `CancellationError`, we land in `catch`, and the tail below
            // still records the exit code and terminates the stream. The tail is
            // synchronous, so it needs no `withTaskCancellationShield`; the
            // deployment target is now macOS 27, so that API is available if the
            // cleanup ever becomes async.
            handle.recordExit(code)
            continuation.finish()
        }

        handle.attach(task)
        return (stream, handle)
    }

    /// Drains one output stream line-by-line into the shared continuation.
    private static func collect(
        _ sequence: SubprocessOutputSequence,
        stream: OutputLine.Stream,
        into continuation: AsyncStream<OutputLine>.Continuation
    ) async {
        do {
            for try await line in sequence.strings() {
                continuation.yield(.init(stream: stream, text: line))
            }
        } catch {
            // Stream closed or errored; ignore — the other stream / termination
            // drives completion.
        }
    }
}
