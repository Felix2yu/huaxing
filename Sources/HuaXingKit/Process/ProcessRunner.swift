import Foundation

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

// MARK: - Internal helpers (visible to ProcessHandle)

/// SIGTERM at deadline, SIGKILL after 5s grace if still alive.
final class Watchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "huaxing.process.watchdog")
    private let timeout: TimeInterval
    private var armed = true
    private let lock = NSLock()
    private var timedOut = false

    init(timeout: TimeInterval) { self.timeout = timeout }

    func start(for process: Process) {
        guard timeout.isFinite, timeout > 0 else { return }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.armed else { return }
            if process.isRunning {
                self.lock.lock(); self.timedOut = true; self.lock.unlock()
                process.terminate()
                let pid = process.processIdentifier
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.armed, kill(pid, 0) == 0 else { return }
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    func cancel() {
        queue.async { self.armed = false }
    }

    var didTimeOut: Bool {
        lock.lock(); let v = timedOut; lock.unlock(); return v
    }
}

/// Handle returned by `ProcessRunner.lines`; call `cancel()` to terminate the
/// subprocess with SIGTERM → 5s grace → SIGKILL escalation.
public final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    private let watchdog: Watchdog?
    private let cancelLock = NSLock()
    private var didCancel = false
    private var launched = false

    init(process: Process, watchdog: Watchdog?) {
        self.process = process
        self.watchdog = watchdog
    }

    /// Set by ProcessRunner immediately after `Process.run()` succeeds.
    func markLaunched() {
        cancelLock.lock(); launched = true; cancelLock.unlock()
    }

    public var isLaunched: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }; return launched
    }

    public var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }; return didCancel
    }

    public var didTimeOut: Bool { watchdog?.didTimeOut ?? false }

    /// Blocks until the subprocess exits and returns its termination status.
    /// Returns -1 when the process was never launched.
    @discardableResult
    public func waitUntilExit() -> Int32 {
        guard isLaunched else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    public func cancel() {
        cancelLock.lock()
        guard !didCancel else { cancelLock.unlock(); return }
        didCancel = true
        cancelLock.unlock()

        watchdog?.cancel()
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
    }
}

// MARK: - ProcessRunner

public enum ProcessRunner {
    public static let enhancedPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func environment(extra: [String: String]?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = enhancedPATH
        if let extra {
            for (k, v) in extra where k != "PATH" { env[k] = v }
        }
        return env
    }

    /// Full-buffered run — returns exit code + both stream strings.
    public static func run(_ spec: ProcessSpec) async -> ProcessResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runBlocking(spec))
            }
        }
    }

    /// Line-streaming variant — yields each newline-terminated (or partial) chunk
    /// as an `OutputLine` on the returned `AsyncStream`. Cancelling the stream
    /// terminates the subprocess.
    public static func lines(_ spec: ProcessSpec) -> (AsyncStream<OutputLine>, ProcessHandle) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = environment(extra: spec.environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let watchdog = Watchdog(timeout: spec.timeout)
        let handle = ProcessHandle(process: process, watchdog: watchdog)

        // Shared bridge — NSLock-protected, holds both line buffers and the
        // continuation. readabilityHandlers dispatch on arbitrary queues; the
        // lock keeps Sendable closure-capture rules happy.
        let bridge = LineStreamBridge()

        let stream = AsyncStream<OutputLine> { continuation in
            bridge.setContinuation(continuation)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [bridge] fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil; bridge.close(stdout: true); return }
            bridge.feed(.stdout, data: data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [bridge] fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil; bridge.close(stdout: false); return }
            bridge.feed(.stderr, data: data)
        }

        bridge.onTerminate = { [weak handle] in handle?.cancel() }

        do {
            try process.run()
            handle.markLaunched()
            watchdog.start(for: process)
        } catch {
            bridge.yieldError("Failed to execute: \(error.localizedDescription)")
            bridge.finish()
        }

        return (stream, handle)
    }

    // MARK: - Blocking implementation

    private static func runBlocking(_ spec: ProcessSpec) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = environment(extra: spec.environment)

        let stdoutBox = OutputBox()
        let stderrBox = OutputBox()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let eofGroup = DispatchGroup()
        eofGroup.enter(); eofGroup.enter()
        installReader(on: stdoutPipe.fileHandleForReading, into: stdoutBox, group: eofGroup)
        installReader(on: stderrPipe.fileHandleForReading, into: stderrBox, group: eofGroup)

        do { try process.run() } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(
                exitCode: -1, stdout: "",
                stderr: "Failed to execute: \(error.localizedDescription)",
                timedOut: false, launched: false
            )
        }

        let watchdog = Watchdog(timeout: spec.timeout)
        watchdog.start(for: process)
        process.waitUntilExit()
        watchdog.cancel()

        _ = eofGroup.wait(timeout: .now() + 2)

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBox.string,
            stderr: stderrBox.string,
            timedOut: watchdog.didTimeOut,
            launched: true
        )
    }

    private static func installReader(
        on handle: FileHandle, into box: OutputBox, group: DispatchGroup
    ) {
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil; group.leave() }
            else { box.append(data) }
        }
    }
}

// MARK: - File-local helpers

/// NSLock-protected Data accumulator for blocking reads.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }
    var string: String {
        lock.lock(); let copy = data; lock.unlock()
        return String(decoding: copy, as: UTF8.self)
    }
}

/// NSLock-protected bridge between readabilityHandlers and AsyncStream continuation.
/// All methods are thread-safe; readabilityHandlers fire on an arbitrary private queue.
private final class LineStreamBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<OutputLine>.Continuation?
    private var stdoutBuf = Data()
    private var stderrBuf = Data()
    private var closedCount = 0
    var onTerminate: (@Sendable () -> Void)?

    func setContinuation(_ c: AsyncStream<OutputLine>.Continuation) {
        lock.lock()
        self.continuation = c
        // Only cancel the subprocess when the *consumer* stops early. A normal
        // EOF-driven `finish()` also terminates the stream, and treating that
        // as cancellation would make every successful run look cancelled.
        c.onTermination = { [weak self] reason in
            if case .cancelled = reason {
                self?.onTerminate?()
            }
        }
        lock.unlock()
    }

    func feed(_ stream: OutputLine.Stream, data: Data) {
        lock.lock()
        var lines: [String] = []
        switch stream {
        case .stdout:
            stdoutBuf.append(data)
            lines = extractLines(&stdoutBuf)
        case .stderr:
            stderrBuf.append(data)
            lines = extractLines(&stderrBuf)
        }
        lock.unlock()
        for line in lines {
            continuation?.yield(.init(stream: stream, text: line))
        }
    }

    private func extractLines(_ buf: inout Data) -> [String] {
        var lines: [String] = []
        while let idx = buf.firstIndex(of: 0x0A) {
            var lineData = buf.prefix(upTo: idx)
            if lineData.last == 0x0D { lineData.removeLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            buf.removeSubrange(0...idx)
        }
        return lines
    }

    func close(stdout: Bool) {
        lock.lock()
        closedCount += 1
        let shouldFinish = closedCount >= 2
        // `stdout == true` means the stdout pipe reached EOF, so flush stdout.
        let restOut = stdout ? flushBuf(&stdoutBuf) : nil
        let restErr = stdout ? nil : flushBuf(&stderrBuf)
        lock.unlock()
        if let s = restOut { continuation?.yield(.init(stream: .stdout, text: s)) }
        if let s = restErr { continuation?.yield(.init(stream: .stderr, text: s)) }
        if shouldFinish { continuation?.finish() }
    }

    func finish() {
        lock.lock()
        continuation?.finish()
        lock.unlock()
    }

    func yieldError(_ msg: String) {
        lock.lock()
        continuation?.yield(.init(stream: .stderr, text: msg))
        lock.unlock()
    }

    private func flushBuf(_ buf: inout Data) -> String? {
        guard !buf.isEmpty else { return nil }
        let s = String(decoding: buf, as: UTF8.self)
        buf.removeAll()
        return s
    }
}

/// Splits raw stream bytes into newline-terminated lines, buffering the tail.
private final class LineBuffer {
    private var buffer = Data()
    func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: idx)
            var trimmed = lineData
            if trimmed.last == 0x0D { trimmed.removeLast() }
            lines.append(String(decoding: trimmed, as: UTF8.self))
            buffer.removeSubrange(0...idx)
        }
        return lines
    }
    func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let s = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return s
    }
}
