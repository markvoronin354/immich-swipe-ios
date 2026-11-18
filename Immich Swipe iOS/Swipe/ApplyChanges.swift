import Foundation

/// What an apply run actually did. Steps fail independently, so this can hold both successes and failures.
nonisolated struct ApplyOutcome: Equatable, Sendable {
    enum Step: String, Hashable, CaseIterable, Sendable {
        case delete, archive, lock, rotation, favorites
    }

    var deletedIDs: [String] = []
    var bytesFreed: Int64 = 0
    var archivedIDs: [String] = []
    var lockedIDs: [String] = []
    /// Kept photos recorded as done. Empty when a delete, archive or lock step failed, so they're
    /// counted in the history on the retry instead of being lost.
    var keptIDs: [String] = []
    var rotatedIDs: [String] = []
    var favoritesApplied: [String: Bool] = [:]
    /// The first error message for each step that failed.
    var failures: [Step: String] = [:]
    /// Immich answers 403 when the API key lacks the permission a step needs.
    var permissionDenied = false

    var hasFailures: Bool { !failures.isEmpty }

    /// IDs whose decision is now fully applied.
    var syncedIDs: [String] { archivedIDs + keptIDs }
    /// IDs that no longer exist in the deck's world: deleted, or moved to the locked folder.
    var removedIDs: [String] { deletedIDs + lockedIDs }

    var changedAnything: Bool {
        !deletedIDs.isEmpty || !archivedIDs.isEmpty || !lockedIDs.isEmpty || !keptIDs.isEmpty
            || !rotatedIDs.isEmpty || !favoritesApplied.isEmpty
    }
}

/// Sends a plan to the server in the order the Android app uses (spec §3.6).
///
/// Each step runs on its own: a failure is recorded, the photos it covered stay pending, and the
/// remaining steps still run. Work is sent in chunks of 500, and a step stops at its first failed
/// chunk, so a dead connection doesn't wait through every remaining chunk.
struct ApplyChanges {
    let client: ImmichClient
    let decisions: DecisionStore
    let userID: String
    var chunkSize = 500

    func run(_ plan: ApplyPlan) async -> ApplyOutcome {
        var outcome = ApplyOutcome()
        AppLog.i("ApplySwipeDecisionsUseCase", "Applying changes: \(plan.delete.count) to delete, \(plan.keep.count) kept, \(plan.archive.count) archive, \(plan.lock.count) locked")

        // 1. Delete. Never forced, so photos go to the Immich trash and can be restored from there.
        let deleted = await process(plan.delete.map(\.id)) { try await client.deleteAssets(ids: $0, force: false) }
        outcome.deletedIDs = deleted.completed
        let sizes = Dictionary(plan.delete.map { ($0.id, $0.fileSize ?? 0) }, uniquingKeysWith: { first, _ in first })
        outcome.bytesFreed = deleted.completed.reduce(0) { $0 + sizes[$1, default: 0] }
        record(deleted.error, for: .delete, in: &outcome)
        // The server change is what matters. If forgetting the local decisions fails, they're stale rows
        // for photos that no longer exist, so it's not reported as a failed delete.
        local("forget deleted decisions") { try decisions.remove(assetIDs: deleted.completed, userID: userID) }

        // 2. Archive.
        let archived = await process(plan.archive.map(\.id)) { try await client.updateAssets(ids: $0, visibility: .archive) }
        outcome.archivedIDs = archived.completed
        record(archived.error, for: .archive, in: &outcome)

        // 3. Lock. Locked photos leave the library view, so their decisions are forgotten too.
        let locked = await process(plan.lock.map(\.id)) { try await client.updateAssets(ids: $0, visibility: .locked) }
        outcome.lockedIDs = locked.completed
        record(locked.error, for: .lock, in: &outcome)
        local("forget locked decisions") { try decisions.remove(assetIDs: locked.completed, userID: userID) }

        // 4. Rotation, one photo at a time. A network error ends the step; other errors skip that photo.
        for rotation in plan.rotations {
            do {
                try await client.editAsset(id: rotation.assetID, rotation: rotation.angle)
                outcome.rotatedIDs.append(rotation.assetID)
            } catch {
                record(error, for: .rotation, in: &outcome)
                if error is URLError { break }
            }
        }

        // 5. Favourites.
        let favoritesOn = await process(plan.favoritesOn) { try await client.updateAssets(ids: $0, isFavorite: true) }
        for id in favoritesOn.completed { outcome.favoritesApplied[id] = true }
        record(favoritesOn.error, for: .favorites, in: &outcome)
        let favoritesOff = await process(plan.favoritesOff) { try await client.updateAssets(ids: $0, isFavorite: false) }
        for id in favoritesOff.completed { outcome.favoritesApplied[id] = false }
        record(favoritesOff.error, for: .favorites, in: &outcome)

        // 6. Local bookkeeping. Kept photos have no server step, so they're only recorded once every
        // delete, archive and lock worked; otherwise a retry would apply and count them properly.
        let coreSucceeded = [ApplyOutcome.Step.delete, .archive, .lock].allSatisfy { outcome.failures[$0] == nil }
        if coreSucceeded { outcome.keptIDs = plan.keep.map(\.id) }
        local("mark synced") { try decisions.markSynced(assetIDs: outcome.syncedIDs, userID: userID) }

        // 7. History, counting only what really happened.
        if !outcome.deletedIDs.isEmpty || !outcome.archivedIDs.isEmpty || !outcome.lockedIDs.isEmpty || !outcome.keptIDs.isEmpty {
            local("record history") {
                try decisions.recordSync(
                    userID: userID,
                    deletedCount: outcome.deletedIDs.count,
                    bytesSaved: outcome.bytesFreed,
                    keptCount: outcome.keptIDs.count,
                    archivedCount: outcome.archivedIDs.count,
                    lockedCount: outcome.lockedIDs.count
                )
            }
        }
        return outcome
    }

    /// Runs `work` over `ids` in chunks, stopping at the first chunk that throws.
    private func process(_ ids: [String], _ work: ([String]) async throws -> Void) async -> (completed: [String], error: Error?) {
        var completed: [String] = []
        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[start..<min(start + chunkSize, ids.count)])
            do {
                try await work(chunk)
                completed += chunk
            } catch {
                return (completed, error)
            }
        }
        return (completed, nil)
    }

    private func record(_ error: Error?, for step: ApplyOutcome.Step, in outcome: inout ApplyOutcome) {
        guard let error else { return }
        AppLog.e("ApplySwipeDecisionsUseCase", "Sync step \(step) failed: \(error.localizedDescription)", error)
        if case ImmichError.http(status: 403, _) = error { outcome.permissionDenied = true }
        guard outcome.failures[step] == nil else { return }
        outcome.failures[step] = error.localizedDescription
    }

    /// Local bookkeeping after a server change. Its failure is only logged, as on Android, so it can't
    /// turn a change that already happened into a reported failure.
    private func local(_ what: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            AppLog.w("ApplySwipeDecisionsUseCase", "Local step '\(what)' failed after the server change was applied: \(error.localizedDescription)")
        }
    }
}
