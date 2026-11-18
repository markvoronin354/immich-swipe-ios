import SwiftUI

/// Everything decided in this deck, grouped by decision, and the button that sends it to the server.
/// Swipe a row to take a decision back before applying.
struct DeckReviewSheet: View {
    let model: DeckModel

    @Environment(\.dismiss) private var dismiss
    @State private var viewerAsset: Asset?

    var body: some View {
        let groups = model.decidedAssets()
        NavigationStack {
            List {
                ReviewTiles(deck: model.deck)

                if let deleted = groups[.delete], !deleted.isEmpty {
                    DeletionGrid(model: model, assets: deleted, viewerAsset: $viewerAsset)
                }

                ApplyPanel(model: model)

                // Part of the list, not an overlay on it, so it sits below the sections instead of on top of them.
                if groups.isEmpty {
                    Section {
                        ContentUnavailableView("Nothing decided yet", systemImage: "hand.draw", description: Text("Swipe right to keep and left to delete."))
                            .frame(maxWidth: .infinity)
                            // Natural height only; it otherwise stretches to fill the list and runs under the Apply button.
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowBackground(Color.clear)
                    }
                }

                // Deletions are in the grid above.
                ForEach([SwipeDecision.archive, .lock, .keep], id: \.self) { decision in
                    if let assets = groups[decision], !assets.isEmpty {
                        Section {
                            ForEach(assets) { asset in
                                ReviewRow(asset: asset, thumbnail: model.thumbnailRequest(for: asset))
                                    .swipeActions {
                                        Button("Undo", systemImage: "arrow.uturn.backward") {
                                            model.removeDecision(for: asset.id)
                                        }
                                        .tint(.blue)
                                    }
                                    .deleteDisabled(model.isApplying)
                            }
                        } header: {
                            Label {
                                Text("\(Self.title(for: decision)) (\(assets.count, format: .number))")
                            } icon: {
                                DecisionBadge(decision: decision)
                            }
                        }
                    }
                }
            }
            // Pinned under the list so Apply is always in reach, like the Android summary's bottom button.
            // A bar rather than a plain inset, so the list fades out under it instead of showing through the disabled button.
            .safeAreaBar(edge: .bottom) { ApplyButton(model: model) }
            // Presented from here rather than from the grid's section, which a List applies to each of its rows.
            .fullScreenCover(item: $viewerAsset) { asset in
                DeletedAssetViewer(model: model, startingAt: asset.id)
            }
            .navigationTitle("Review")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(model.isApplying)
                }
            }
            // Closing the sheet mid-apply would hide the result, so it stays until the run finishes.
            .interactiveDismissDisabled(model.isApplying)
        }
    }

    static func title(for decision: SwipeDecision) -> LocalizedStringResource {
        switch decision {
        case .keep: "Keep"
        case .delete: "Delete"
        case .archive: "Archive"
        case .lock: "Lock"
        }
    }
}

// MARK: - Apply

private struct ApplyPanel: View {
    let model: DeckModel

    var body: some View {
        let plan = model.plan
        Section {
            if plan.isEmpty {
                Label("Nothing is waiting to be applied.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                PlanLine(title: "Move to the Immich trash", systemImage: "trash", count: plan.delete.count, detail: bytes(plan.bytesToFree))
                PlanLine(title: "Archive", systemImage: "archivebox", count: plan.archive.count)
                PlanLine(title: "Move to the locked folder", systemImage: "lock", count: plan.lock.count)
                PlanLine(title: "Favorite changes", systemImage: "heart", count: plan.favoritesOn.count + plan.favoritesOff.count)
                PlanLine(title: "Rotate", systemImage: "rotate.right", count: plan.rotations.count)
                PlanLine(title: "Keep as they are", systemImage: "checkmark", count: plan.keep.count)
            }

            if !plan.skippedRotationIDs.isEmpty {
                Text("^[\(plan.skippedRotationIDs.count) photo](inflect: true) already edited in Immich won't be rotated, so an existing crop isn't lost.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let outcome = model.lastOutcome {
                OutcomeLines(outcome: outcome)
            }
        } header: {
            Text("Apply to Server")
        } footer: {
            Text("Deleted photos go to the Immich trash, which keeps them for 30 days by default, so you can still restore them.")
        }
    }

    private func bytes(_ value: Int64) -> String? {
        value > 0 ? value.formatted(.byteCount(style: .file)) : nil
    }
}

/// The sheet's main action. Red when it deletes, as on Android, and kept out of the scrolling list.
private struct ApplyButton: View {
    let model: DeckModel
    @State private var isConfirming = false

    var body: some View {
        let plan = model.plan
        Button {
            isConfirming = true
        } label: {
            Group {
                if model.isApplying {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Applying…")
                    }
                } else {
                    Text("Apply Changes…")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(plan.delete.isEmpty ? .accentColor : .red)
        .disabled(plan.isEmpty || model.isApplying)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .confirmationDialog(
            "Apply \(plan.pendingCount) changes?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(plan.delete.isEmpty ? "Apply Changes" : "Move to Trash and Apply", role: plan.delete.isEmpty ? nil : .destructive) {
                // A separate task, so closing the screen never cancels half an apply.
                Task { await model.apply() }
            }
        } message: {
            // The full breakdown is already listed under Apply to Server, so only the deletion is called out.
            if !plan.delete.isEmpty {
                if plan.bytesToFree > 0 {
                    Text("^[\(plan.delete.count) photo](inflect: true) (\(plan.bytesToFree.formatted(.byteCount(style: .file)))) will be moved to the Immich trash.")
                } else {
                    Text("^[\(plan.delete.count) photo](inflect: true) will be moved to the Immich trash.")
                }
            }
        }
    }
}

private struct PlanLine: View {
    let title: LocalizedStringKey
    let systemImage: String
    let count: Int
    var detail: String?

    var body: some View {
        if count > 0 {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(count, format: .number).fontWeight(.semibold)
                    if let detail { Text("· \(detail)").foregroundStyle(.secondary) }
                }
                .monospacedDigit()
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }
}

/// What the last apply did: a success line, or one line per step that failed.
private struct OutcomeLines: View {
    let outcome: ApplyOutcome

    var body: some View {
        if !outcome.hasFailures {
            Label {
                if outcome.bytesFreed > 0 {
                    Text("Applied. Freed \(outcome.bytesFreed.formatted(.byteCount(style: .file))).")
                } else {
                    Text("Applied.")
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Some changes didn't go through", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                ForEach(ApplyOutcome.Step.allCases.filter { outcome.failures[$0] != nil }, id: \.self) { step in
                    Text("\(Self.title(for: step)): \(outcome.failures[step] ?? "")")
                        .font(.footnote)
                }
                if outcome.permissionDenied {
                    Text("The server refused some changes. Check that your Immich API key has every permission Immich Swipe needs (see the README).")
                        .font(.footnote)
                }
                Text("Everything else was applied. Tap Apply Changes to try the rest again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func title(for step: ApplyOutcome.Step) -> String {
        switch step {
        case .delete: String(localized: "Move to trash")
        case .archive: String(localized: "Archive")
        case .lock: String(localized: "Lock")
        case .rotation: String(localized: "Rotate")
        case .favorites: String(localized: "Favorites")
        }
    }
}

// MARK: - Review list

private extension SwipeDecision {
    var symbol: String {
        switch self {
        case .keep: "checkmark"
        case .delete: "trash"
        case .archive: "archivebox"
        case .lock: "lock"
        }
    }

    var tint: Color {
        switch self {
        case .keep: .green
        case .delete: .red
        case .archive: .blue
        case .lock: .gray
        }
    }
}

#if os(iOS)
private let tileFill = Color(.secondarySystemGroupedBackground)
#else
private let tileFill = Color.secondary.opacity(0.15)
#endif

/// Keep, Delete, Archive and Locked as a connected 2×2 group, as at the top of the Android summary.
private struct ReviewTiles: View {
    let deck: Deck

    var body: some View {
        Section {
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    ReviewTile(decision: .keep, deck: deck, isTop: true, isLeading: true)
                    ReviewTile(decision: .delete, deck: deck, isTop: true, isLeading: false)
                }
                GridRow {
                    ReviewTile(decision: .archive, deck: deck, isTop: false, isLeading: true)
                    ReviewTile(decision: .lock, deck: deck, isTop: false, isLeading: false)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }
}

private struct ReviewTile: View {
    let decision: SwipeDecision
    let deck: Deck
    let isTop: Bool
    let isLeading: Bool

    var body: some View {
        let count = deck.pileCount(of: [decision])
        VStack(spacing: 8) {
            HStack {
                Image(systemName: decision.symbol)
                    .font(.headline)
                    .foregroundStyle(decision.tint)
                    .frame(width: 40, height: 40)
                    .background(decision.tint.opacity(0.18), in: .circle)
                Spacer()
                Text(count, format: .number)
                    .font(.title2.bold())
                    .monospacedDigit()
            }
            Text(deck.bytes(of: decision), format: .byteCount(style: .file))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(tileFill, in: corners)
        // The badge has no label of its own, so VoiceOver reads the decision with its numbers.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(DeckReviewSheet.title(for: decision)))
    }

    /// Only the corners on the group's outside edge are fully rounded.
    private var corners: UnevenRoundedRectangle {
        let outer: CGFloat = 24
        let inner: CGFloat = 6
        return UnevenRoundedRectangle(
            topLeadingRadius: isTop && isLeading ? outer : inner,
            bottomLeadingRadius: !isTop && isLeading ? outer : inner,
            bottomTrailingRadius: !isTop && !isLeading ? outer : inner,
            topTrailingRadius: isTop && !isLeading ? outer : inner
        )
    }
}

/// The photos about to be deleted, to check before applying (Android: "Check before deletion").
private struct DeletionGrid: View {
    let model: DeckModel
    let assets: [Asset]
    /// The photo to open full screen, where its deletion can be taken back.
    @Binding var viewerAsset: Asset?

    var body: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(assets) { asset in
                    DeletionThumbnail(asset: asset, thumbnail: model.thumbnailRequest(for: asset), isFavorite: model.isFavorite(asset))
                        .onTapGesture { viewerAsset = asset }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Check Before Deletion")
                Spacer()
                Text("^[\(assets.count) photo](inflect: true)")
            }
        }
    }
}

private struct DeletionThumbnail: View {
    let asset: Asset
    let thumbnail: URLRequest
    let isFavorite: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    RemoteThumbnail(request: thumbnail, size: proxy.size.width, cornerRadius: 12)
                }
            }
            .overlay(alignment: .topLeading) {
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.type == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(.black.opacity(0.4), in: .circle)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottom) {
                if let size = asset.fileSize {
                    Text(size, format: .byteCount(style: .file))
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                }
            }
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(asset.originalFileName ?? asset.id))
    }
}

private struct ReviewRow: View {
    let asset: Asset
    let thumbnail: URLRequest

    var body: some View {
        HStack(spacing: 12) {
            RemoteThumbnail(request: thumbnail, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.originalFileName ?? asset.id)
                    .lineLimit(1)
                if let size = asset.fileSize {
                    Text(size, format: .byteCount(style: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
