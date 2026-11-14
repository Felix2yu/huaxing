import Foundation

// Minimal leveled logger — routes everything through stderr so --json stdout stays clean.
public enum Log {
    public enum Level: Sendable { case info, success, warn, error }

    public static func info(_ msg: String) { write("ℹ  \(msg)") }
    public static func success(_ msg: String) { write("✔  \(msg)") }
    public static func warn(_ msg: String) { write("⚠  \(msg)") }
    public static func error(_ msg: String) { write("✖  \(msg)") }

    private static func write(_ line: String) {
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }
}
