import SwiftUI

/// Adds the current photo to an existing album, or to a new one. This writes to the server
/// immediately, like on Android, because adding to an album never removes anything.
struct AddToAlbumSheet: View {
    let model: DeckModel
    let asset: Asset

    private let prefs = DeckPreferences()

    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album]?
    @State private var query = ""
    @State private var newAlbumName = ""
    @State private var workingAlbumID: String?
    @State private var errorMessage: String?
    @State private var addedTo: String?
    /// Set once Archive or Lock has been chosen here, for the confirmation.
    @State private var decided: SwipeDecision?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New album name", text: $newAlbumName)
                            .onSubmit(createAlbum)
                        Button("Create", action: createAlbum)
                            .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty || workingAlbumID != nil)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section("Albums") {
                    // With no dedicated archive or lock button, they're offered here instead, like Android does for
                    // lock. Android has no archive row; it's the same row for the other button.
                    if !prefs.showArchiveButton && matches("Archive", aliases: ["archive", "archiv"]) {
                        DecisionRow(
                            systemImage: "archivebox.fill",
                            title: "Archive",
                            subtitle: "Move asset to archive",
                            action: { decide(.archive) }
                        )
                        .disabled(workingAlbumID != nil || decided != nil)
                    }
                    if !prefs.showLockButton && matches("Locked folder", aliases: ["lock", "verrouil", "bloque"]) {
                        DecisionRow(
                            systemImage: "lock.fill",
                            title: "Locked folder",
                            subtitle: "Move asset to locked folder",
                            action: { decide(.lock) }
                        )
                        .disabled(workingAlbumID != nil || decided != nil)
                    }
                    if let albums {
                        ForEach(filtered(albums)) { album in
                            Button {
                                add(to: album)
                            } label: {
                                HStack {
                                    Text(album.albumName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if workingAlbumID == album.id {
                                        ProgressView()
                                    } else {
                                        Text(album.assetCount, format: .number)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(workingAlbumID != nil)
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            .searchable(text: $query, prompt: "Search albums")
            .navigationTitle("Add to Album")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if let decided {
                    Label(decided == .archive ? "Asset archived" : "Asset locked", systemImage: decided == .archive ? "archivebox.fill" : "lock.fill")
                        .font(.headline)
                        .padding()
                        .glassEffect(.regular.tint(.green.opacity(0.3)), in: .capsule)
                        .transition(.scale.combined(with: .opacity))
                } else if let addedTo {
                    Label("Added to \(addedTo)", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .padding()
                        .glassEffect(.regular.tint(.green.opacity(0.3)), in: .capsule)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .task {
                do {
                    albums = try await model.loadAlbums()
                } catch {
                    AppLog.e("SwipeViewModel", "Error loading albums for dialog", error)
                    albums = []
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func filtered(_ albums: [Album]) -> [Album] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? albums : albums.filter { $0.albumName.localizedStandardContains(trimmed) }
    }

    /// A row stays while the search is empty or matches its title or one of its keywords, like Android's
    /// locked folder row.
    private func matches(_ title: String.LocalizationValue, aliases: [String]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        let q = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(localized: title).localizedStandardContains(trimmed)
            || aliases.contains { $0.contains(q) }
    }

    /// Records the decision, the same as the toolbar button, then closes. Android doesn't animate the card here.
    private func decide(_ decision: SwipeDecision) {
        model.decide(decision)
        withAnimation { decided = decision }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            dismiss()
        }
    }

    private func add(to album: Album) {
        run(albumID: album.id, name: album.albumName) {
            try await model.add(asset, to: album)
        }
    }

    private func createAlbum() {
        let name = newAlbumName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, workingAlbumID == nil else { return }
        run(albumID: "new", name: name) {
            _ = try await model.createAlbum(named: name, with: asset)
        }
    }

    private func run(albumID: String, name: String, _ work: @escaping () async throws -> Void) {
        workingAlbumID = albumID
        errorMessage = nil
        Task {
            defer { workingAlbumID = nil }
            do {
                try await work()
                withAnimation { addedTo = name }
                try? await Task.sleep(for: .milliseconds(700))
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A tile row at the top of the album list for a decision that has no toolbar button: an icon, a title and
/// what it does.
private struct DecisionRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.tint, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tint)
            }
        }
    }
}
