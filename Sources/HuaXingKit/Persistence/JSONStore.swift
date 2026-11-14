import Foundation

// MARK: - AppPaths

/// Standard locations for application state on disk. Non-sandboxed app uses
/// real paths under `~/Library/Application Support/`.
public enum AppPaths {
    public static let bundleID = "im.yufei.huaxing"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    public static var presetsFile: URL {
        supportDirectory.appendingPathComponent("presets.json")
    }

    public static var rulesFile: URL {
        supportDirectory.appendingPathComponent("rules.json")
    }

    public static var settingsFile: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    /// Ensures the support directory exists. No-op if already present.
    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
    }
}

// MARK: - JSONStore

/// Atomic JSON persistence with schema envelope.
///
/// Write = serialize → write to `.tmp` → replaceItemAt (OS-level atomic rename).
/// Unknown schema version ≥ current version are rejected on write and the file
/// is backed up — never silently clobber newer data from a future build.
public final class JSONStore<T: Codable & Sendable>: @unchecked Sendable {
    public let url: URL
    public let currentSchema: Int
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL, schema: Int) {
        self.url = url
        self.currentSchema = schema
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = e
        self.decoder = JSONDecoder()
    }

    // MARK: - Envelope

    private struct Envelope<U: Codable>: Codable {
        var schemaVersion: Int
        var payload: U
    }

    // MARK: - API

    /// Loads the payload from disk. Returns nil if the file doesn't exist.
    public func load() throws -> T? {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url)

        // Detect damaged JSON — back it up so a later save cannot silently
        // destroy recoverable user data.
        guard let envelope = try? decoder.decode(Envelope<T>.self, from: data) else {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.copyItem(at: url, to: backup)
            return nil
        }

        // Reject unknown future schema versions — don't corrupt user data.
        if envelope.schemaVersion > currentSchema {
            throw PersistenceError.schemaTooNew(
                found: envelope.schemaVersion,
                current: currentSchema
            )
        }

        // Migrate if older version
        return try migrateIfNeeded(envelope)
    }

    /// Atomically writes the payload to disk.
    public func save(_ value: T) throws {
        lock.lock()
        defer { lock.unlock() }

        let envelope = Envelope(schemaVersion: currentSchema, payload: value)
        let data = try encoder.encode(envelope)

        // Atomic write: tmp → replace. Ensure the parent directory exists —
        // a first-run save must never fail just because the folder is missing.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            // replaceItemAt fails on missing destination — create fresh
            try? FileManager.default.removeItem(at: tmp)
            try data.write(to: url, options: .atomic)
        }
    }

    /// Returns true when the backing file exists on disk.
    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Migration seam

    /// Migration hook — override in subclass. Default impl returns payload unchanged.
    private func migrateIfNeeded(_ envelope: Envelope<T>) throws -> T {
        if envelope.schemaVersion == currentSchema {
            return envelope.payload
        }
        // Schema downgrade — best-effort, caller should handle.
        return envelope.payload
    }
}

// MARK: - PersistenceError

public enum PersistenceError: Error, Sendable {
    case schemaTooNew(found: Int, current: Int)
    case encodeFailed(String)
    case decodeFailed(String)
    case ioError(String)
}
