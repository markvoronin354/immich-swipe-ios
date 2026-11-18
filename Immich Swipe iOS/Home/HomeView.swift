import SwiftUI

/// Album list: special collections first, then albums grouped by how far through them the user is.
struct HomeView: View {
    @Environment(SessionStore.self) private var session
    let account: Account
    @State private var model: HomeModel
    @State private var query = ""
    @State private var isShowingStatistics = false
    // Android starts with every album group collapsed except the special collections.
    @State private var expanded: Set<String> = ["Special Collections"]
    @AppStorage(Setting.Key.backupWarningShown) private var backupWarningShown = Setting.Default.backupWarningShown
    @AppStorage(Setting.Key.includeArchived) private var includeArchived = Setting.Default.includeArchived

    init(account: Account, model: HomeModel) {
        self.account = account
        _model = State(initialValue: model)
    }

    var body: some View {
        let sections = model.sections(query: query)
        List {
            if let errorMessage = model.errorMessage, model.albums.isEmpty {
                LoadErrorRow(message: errorMessage) { Task { await model.load() } }
            }
            HomeSection(title: "Special Collections", id: "Special Collections", entries: sections.collections, client: model.client, expanded: $expanded)
            HomeSection(title: "In Progress", id: "In Progress", entries: sections.inProgress, client: model.client, expanded: $expanded)
            HomeSection(title: "Not Started", id: "Not Started", entries: sections.notStarted, client: model.client, expanded: $expanded)
            HomeSection(title: "Completed", id: "Completed", entries: sections.completed, client: model.client, expanded: $expanded)
        }
        .overlay {
            if !model.hasLoaded {
                ProgressView()
            } else if sections.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Search albums")
        .navigationTitle("Immich Swipe")
        .navigationDestination(for: HomeEntry.self) { entry in
            // Duplicates have their own screen, as on Android, rather than a swipe deck.
            if entry.kind == .duplicates {
                DuplicatesView(model: DuplicatesModel(client: model.client, userID: model.userID, decisions: model.decisions))
            } else {
                SwipeDeckView(model: DeckModel(
                    title: entry.album.albumName,
                    source: DeckSource(entry),
                    client: model.client,
                    userID: model.userID,
                    decisions: model.decisions,
                    shuffleSeed: session.shuffleSeed
                ))
            }
        }
        .navigationDestination(for: SettingsRoute.self) { _ in
            SettingsView(model: SettingsModel(account: account, client: model.client, decisions: model.decisions))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Statistics", systemImage: "chart.bar") { isShowingStatistics = true }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            // No glass behind the avatar: it is already a round picture.
            ToolbarItem(placement: .primaryAction) {
                ProfileButton()
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: $isShowingStatistics) {
            StatisticsSheet(
                decisions: model.decisions,
                userID: model.userID,
                totalAlbums: model.albums.count,
                completedAlbums: sections.completed.count
            )
        }
        // One-time notice, like Android's. Its text points to "Sync deletion with device", which
        // iOS doesn't have, so the message explains what happens to the copy on the phone instead.
        .alert("Storage Sync", isPresented: Binding(get: { !backupWarningShown }, set: { if !$0 { backupWarningShown = true } })) {
            Button("Confirm") { backupWarningShown = true }
        } message: {
            Text("Deleting a photo here removes it from your Immich server only. The copy on this device stays, so the Immich app may back it up again.\n\nTo prevent that, also delete it from the Photos app.")
        }
        .refreshable { await model.load() }
        .task { if !model.hasLoaded { await model.load() } }
        // The counts change with "Include external archives", so Home reloads, as on Android.
        .task(id: includeArchived) { if model.hasLoaded { await model.load() } }
        .onAppear { model.refreshProgress() }
    }
}

private struct HomeSection: View {
    let title: LocalizedStringKey
    let id: String
    let entries: [HomeEntry]
    let client: ImmichClient
    @Binding var expanded: Set<String>

    private var isExpanded: Bool { expanded.contains(id) }

    var body: some View {
        if !entries.isEmpty {
            Section {
                if isExpanded {
                    ForEach(entries) { entry in
                        NavigationLink(value: entry) {
                            AlbumRow(entry: entry, thumbnail: thumbnailRequest(for: entry))
                        }
                    }
                }
            } header: {
                Button {
                    withAnimation {
                        if isExpanded { expanded.remove(id) } else { expanded.insert(id) }
                    }
                } label: {
                    HStack {
                        Text(title)
                        Text(entries.count, format: .number)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }
        }
    }

    private func thumbnailRequest(for entry: HomeEntry) -> URLRequest? {
        guard let assetID = entry.album.albumThumbnailAssetId else { return nil }
        return client.authorizedRequest(for: .thumbnail(assetID: assetID))
    }
}

private struct AlbumRow: View {
    let entry: HomeEntry
    let thumbnail: URLRequest?

    var body: some View {
        HStack(spacing: 12) {
            switch entry.kind {
            case .album:
                RemoteThumbnail(request: thumbnail)
            case .all, .orphans, .duplicates:
                CollectionIcon(kind: entry.kind)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.album.albumName)
                    .lineLimit(1)
                ProgressLine(entry: entry)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if entry.progress.unsynced > 0 {
                Text("\(entry.progress.unsynced, format: .number) to apply")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.18), in: .capsule)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProgressLine: View {
    let entry: HomeEntry

    var body: some View {
        if entry.nothingToSort {
            Text("Nothing to sort")
        } else if let total = entry.assetCount {
            if entry.isCompleted {
                Label("Completed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else if entry.decidedCount > 0 {
                Text("\(entry.decidedCount, format: .number) of \(total, format: .number) sorted")
            } else {
                Text("^[\(total) item](inflect: true)")
            }
        } else {
            Text("Count unavailable")
        }
    }
}

private struct CollectionIcon: View {
    let kind: HomeEntry.Kind

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(color.gradient)
            .frame(width: 56, height: 56)
            .overlay {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.white)
            }
    }

    private var symbol: String {
        switch kind {
        case .all: "photo.stack"
        case .orphans: "rectangle.stack.badge.minus"
        case .duplicates: "square.on.square"
        case .album: "photo"
        }
    }

    private var color: Color {
        switch kind {
        case .all: .blue
        case .orphans: .purple
        case .duplicates: .teal
        case .album: .gray
        }
    }
}

private struct LoadErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't load your albums", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Try Again", action: retry)
            }
            .padding(.vertical, 4)
        }
    }
}
