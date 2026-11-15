import Foundation
import Testing
@testable import Immich_Swipe_iOS

/// The log file behaves like Android's `AppLogger`: line format, 1 MB rotation, headers and clearing.
struct AppLogTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AppLogTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func emptyWhenNothingWasLogged() {
        #expect(LogFile(directory: directory).contents().isEmpty)
    }

    @Test func writesAndroidLineFormat() throws {
        let file = LogFile(directory: directory)
        let parts = DateComponents(year: 2026, month: 1, day: 31, hour: 14, minute: 5, second: 9, nanosecond: 123_000_000)
        let date = try #require(Calendar(identifier: .gregorian).date(from: parts))

        file.append(level: "E", tag: "Auth", message: "Connection failed", date: date)

        #expect(file.contents() == "--- CURRENT LOGS ---\n2026-01-31 14:05:09.123 E/Auth: Connection failed\n")
    }

    /// The real folder is "Library/Application Support", which has a space in it.
    @Test func writesIntoAFolderWithASpace() {
        let file = LogFile(directory: directory.appending(path: "Application Support", directoryHint: .isDirectory))
        file.appendRaw("hello\n")

        #expect(file.contents() == "--- CURRENT LOGS ---\nhello\n")
    }

    @Test func rotatesPastOneMegabyte() throws {
        let file = LogFile(directory: directory)
        file.appendRaw(String(repeating: "a", count: LogFile.maxFileSize + 1))
        file.appendRaw("newest\n")

        let contents = file.contents()
        #expect(contents.hasPrefix("--- PREVIOUS LOGS ---\naaa"))
        #expect(contents.hasSuffix("\n\n--- CURRENT LOGS ---\nnewest\n"))
        let previousSize = try FileManager.default.attributesOfItem(atPath: file.previous.path(percentEncoded: false))[.size] as? Int
        #expect(previousSize == LogFile.maxFileSize + 1)
    }

    @Test func logFilesAreExcludedFromBackup() throws {
        let file = LogFile(directory: directory)
        file.appendRaw(String(repeating: "a", count: LogFile.maxFileSize + 1))
        file.appendRaw("newest\n")
        _ = file.contents() // waits for the writes

        #expect(try file.current.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try file.previous.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func clearRemovesBothFiles() {
        let file = LogFile(directory: directory)
        file.appendRaw(String(repeating: "a", count: LogFile.maxFileSize + 1))
        file.appendRaw("newest\n")

        file.clear()

        #expect(file.contents().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.current.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: file.previous.path(percentEncoded: false)))
    }
}
