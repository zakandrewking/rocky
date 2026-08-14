import Foundation

/// A durable, file-based log, pulled off the device after a test session the same way crash
/// reports are: `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier
/// family.rocky.ios --source Documents/session.log --destination <local path>`. In-app UI state
/// (ContentView's scrolling log list) isn't remotely readable and is lost on backgrounding --
/// this is what makes "what did it hear, what did it do" answerable after the fact.
enum RockyLog {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("session.log")
    }()

    static func write(_ line: String) {
        // A fresh formatter per call, not a shared static one -- write() is called from several
        // different concurrency contexts (MainActor UI code, nonisolated audio-thread helpers),
        // and ISO8601DateFormatter isn't Sendable. Log lines are infrequent enough that this
        // isn't worth reaching for nonisolated(unsafe) over.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = "[\(formatter.string(from: Date()))] \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}
