import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A backup file to hand to the system's save dialog.
nonisolated struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// What the Settings screen needs beyond plain preferences: the signed-in user's details, the
/// database actions, and the image cache.
@Observable
final class SettingsModel {
    /// Whose data an export or delete covers.
    enum Scope: Hashable { case account, allAccounts }

    let account: Account
    let client: ImmichClient
    private let decisions: DecisionStore

    private(set) var user: User?
    private(set) var cacheBytes = 0
    /// Set to show a one-line result in an alert.
    var message: String?
    /// The file waiting to be saved, while the save dialog is up.
    var exportDocument: BackupDocument?

    init(account: Account, client: ImmichClient, decisions: DecisionStore) {
        self.account = account
        self.client = client
        self.decisions = decisions
    }

    // MARK: Account and cache

    func load() async {
        do {
            user = try await client.getMyUser()
        } catch {
            AppLog.e("SettingsVM", "Error loading user", error)
        }
        cacheBytes = await ThumbnailLoader.shared.diskUsage
    }

    func clearCache() async {
        await ThumbnailLoader.shared.clearCache()
        cacheBytes = await ThumbnailLoader.shared.diskUsage
        message = String(localized: "Cache cleared.")
    }

    // MARK: Database

    var exportFileName: String {
        "immich_swipe_backup_\(exportScope == .allAccounts ? "total" : "user")_\(BackupExport.milliseconds(.now))"
    }
    private var exportScope = Scope.account

    /// Builds the backup and queues it for the save dialog. Returns false if it couldn't be built.
    func prepareExport(_ scope: Scope) -> Bool {
        exportScope = scope
        do {
            exportDocument = BackupDocument(data: try decisions.exportBackup(userID: scope == .account ? account.userID : nil))
            return true
        } catch {
            message = String(localized: "Export error: \(error.localizedDescription)")
            return false
        }
    }

    func finishExport(_ result: Result<URL, Error>) {
        exportDocument = nil
        switch result {
        case .success: message = String(localized: "Backup saved.")
        case .failure(let error): message = String(localized: "Export error: \(error.localizedDescription)")
        }
    }

    func importBackup(from result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let imported = try decisions.importBackup(fromFileAt: url)
                message = HomeModel.message(for: imported, userID: account.userID)
            } catch {
                message = String(localized: "Import error: \(error.localizedDescription)")
            }
        case .failure(let error):
            message = String(localized: "Import error: \(error.localizedDescription)")
        }
    }

    func deleteData(_ scope: Scope) {
        do {
            switch scope {
            case .account: try decisions.removeAllData(userID: account.userID)
            case .allAccounts: try decisions.removeAllAccountsData()
            }
            message = String(localized: "Data deleted successfully.")
        } catch {
            message = String(localized: "Couldn't delete the data: \(error.localizedDescription)")
        }
    }
}
