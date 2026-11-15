import Foundation
import os

/// The app's log, ported from Android's `core/AppLogger.kt`. Each entry goes to the system log
/// (Xcode console, Console.app) and to a file the user can read and copy from "System Logs".
/// The file keeps the previous log too, so the session before a crash can still be sent.
nonisolated enum AppLog {
    static let file = LogFile(directory: .applicationSupportDirectory)

    private static let subsystem = Bundle.main.bundleIdentifier ?? "ImmichSwipe"

    /// Marks a new session in the file. Called once at launch, like Android's `AppLogger.init`.
    static func startSession() {
        let rule = String(repeating: "=", count: 50)
        file.appendRaw("\n\n\(rule)\n   NEW SESSION START   \n\(rule)\n\n")
    }

    static func d(_ tag: String, _ message: String) {
        write(.debug, "D", tag, message)
    }

    static func i(_ tag: String, _ message: String) {
        write(.info, "I", tag, message)
    }

    static func w(_ tag: String, _ message: String, _ error: (any Error)? = nil) {
        write(.default, "W", tag, message, error)
    }

    static func e(_ tag: String, _ message: String, _ error: (any Error)? = nil) {
        write(.error, "E", tag, message, error)
    }

    private static func write(_ type: OSLogType, _ level: String, _ tag: String, _ message: String, _ error: (any Error)? = nil) {
        let text = error.map { "\(message) \(String(describing: $0))" } ?? message
        Logger(subsystem: subsystem, category: tag).log(level: type, "\(text, privacy: .public)")
        file.append(level: level, tag: tag, message: text)
    }
}

/// The log files: `current_logs.txt`, moved to `previous_logs.txt` once it passes 1 MB, as on Android.
/// Writes happen in order on a background queue; reading and clearing wait for them first.
nonisolated final class LogFile: Sendable {
    static let maxFileSize = 1024 * 1024

    let current: URL
    let previous: URL
    private let queue = DispatchQueue(label: "AppLog.file", qos: .utility)

    /// Android's `yyyy-MM-dd HH:mm:ss.SSS`, in local time.
    private static let timestamp = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
        timeZone: .current,
        calendar: Calendar(identifier: .gregorian)
    )

    init(directory: URL) {
        current = directory.appending(path: "current_logs.txt")
        previous = directory.appending(path: "previous_logs.txt")
    }

    /// Adds one line: `2026-01-31 14:05:09.123 E/Tag: message`.
    func append(level: String, tag: String, message: String, date: Date = .now) {
        appendRaw("\(date.formatted(Self.timestamp)) \(level)/\(tag): \(message)\n")
    }

    func appendRaw(_ text: String) {
        queue.async { self.write(text) }
    }

    /// The previous log then the current one, under Android's headers. Empty when there are no logs.
    func contents() -> String {
        queue.sync {
            var logs = ""
            if FileManager.default.fileExists(atPath: previous.path(percentEncoded: false)) {
                logs += "--- PREVIOUS LOGS ---\n"
                do { logs += try String(contentsOf: previous, encoding: .utf8) } catch { logs += "Error reading previous logs: \(error.localizedDescription)\n" }
                logs += "\n\n"
            }
            if FileManager.default.fileExists(atPath: current.path(percentEncoded: false)) {
                logs += "--- CURRENT LOGS ---\n"
                do { logs += try String(contentsOf: current, encoding: .utf8) } catch { logs += "Error reading current logs: \(error.localizedDescription)\n" }
            }
            return logs
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: current)
            try? FileManager.default.removeItem(at: previous)
        }
    }

    /// Runs on `queue` only.
    private func write(_ text: String) {
        let fileManager = FileManager.default
        do {
            if let size = try? fileManager.attributesOfItem(atPath: current.path(percentEncoded: false))[.size] as? Int, size > Self.maxFileSize {
                try? fileManager.removeItem(at: previous)
                try fileManager.moveItem(at: current, to: previous)
            }
            if !fileManager.fileExists(atPath: current.path(percentEncoded: false)) {
                try fileManager.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
                fileManager.createFile(atPath: current.path(percentEncoded: false), contents: nil)
                // Like Android's backup rules, keep the logs (server address, account) out of device backups.
                // The setting stays with the file when it rotates to `previous`.
                var excluded = current
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? excluded.setResourceValues(values)
            }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            Logger(subsystem: "AppLog", category: "AppLog").error("Failed to write log to file: \(error, privacy: .public)")
        }
    }
}
