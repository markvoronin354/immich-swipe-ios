import SwiftUI

/// The duplicates screen, laid out like Android's (`DuplicatesScreen.kt`): a progress pill and counts,
/// the groups one card at a time in a snapping list, and Sort and Select at the bottom. Tapping the pill
/// deletes the assets marked Delete, after a confirmation.
///
/// Android's tutorial for this screen is not ported: the iOS app has no tutorial system yet.
struct DuplicatesView: View {
    @State private var model: DuplicatesModel
    @State private var peek: DuplicatePeek?
    @State private var viewerStart: ViewerStart?
    /// The group the viewer was last showing, so the list can scroll to it when the viewer closes.
    @State private var viewerClusterIndex = 0
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    /// Where each card on screen (or recently on screen) sits in the list, for centre snapping.
    @State private var cardFrames: [Int: CGRect] = [:]
    @State private var isConfirmingReset = false
    @State private var isConfirmingDelete = false
    @State private var showsNoDeletions = false
    /// The auto-select waiting on "Apply to which groups?".
    @State private var pendingAutoSelect: DuplicatesModel.AutoSelectMode?

    struct ViewerStart: Identifiable {
        let clusterIndex: Int
        let assetIndex: Int
        var id: String { "\(clusterIndex)-\(assetIndex)" }
    }

    init(model: DuplicatesModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        content
            .navigationTitle("Duplicates")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset Decisions", systemImage: "arrow.clockwise") { isConfirmingReset = true }
                        .tint(.red)
                        .disabled(model.keepCount + model.deleteCount == 0)
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                // No glass behind the avatar: it is already a round picture.
                ToolbarItem(placement: .primaryAction) {
                    ProfileButton()
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .alert("Reset Duplicate Choices?", isPresented: $isConfirmingReset) {
                Button("Cancel", role: .cancel) {}
                Button("Confirm", role: .destructive) { model.reset() }
            } message: {
                Text("This will clear all local KEEP/DELETE choices for duplicate clusters.")
            }
            .alert("Delete Duplicate Photos?", isPresented: $isConfirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { Task { await model.deleteMarked() } }
            } message: {
                Text("This will permanently delete ^[\(model.deleteCount) photo](inflect: true) (\(DuplicateFormat.size(model.deleteBytes))) from your Immich server. Are you sure?")
            }
            // Android only logs a failed delete. Here the user is told, since the photos are still there.
            .alert("Couldn't Delete", isPresented: Binding(get: { model.syncError != nil }, set: { if !$0 { model.syncError = nil } })) {
                Button("OK") { model.syncError = nil }
            } message: {
                Text(model.syncError ?? "")
            }
            .overlay {
                if let peek {
                    DuplicatePeekOverlay(peek: peek, model: model)
                }
            }
            .overlay {
                if model.isSyncing { SyncingOverlay() }
            }
            .overlay(alignment: .top) {
                // Android shows a toast.
                if showsNoDeletions {
                    Label("No photos to delete.", systemImage: "info.circle")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: showsNoDeletions)
            .task(id: showsNoDeletions) {
                guard showsNoDeletions else { return }
                try? await Task.sleep(for: .seconds(2))
                showsNoDeletions = false
            }
            #if os(iOS)
            .fullScreenCover(item: $viewerStart, onDismiss: scrollToViewerCluster) { start in
                DuplicatesViewer(model: model, clusterIndex: start.clusterIndex, assetIndex: start.assetIndex, activeClusterIndex: $viewerClusterIndex)
            }
            #else
            .sheet(item: $viewerStart, onDismiss: scrollToViewerCluster) { start in
                DuplicatesViewer(model: model, clusterIndex: start.clusterIndex, assetIndex: start.assetIndex, activeClusterIndex: $viewerClusterIndex)
                    .frame(minWidth: 700, minHeight: 500)
            }
            #endif
            .sensoryFeedback(.impact(weight: .light), trigger: model.keepCount + model.deleteCount)
            // Only the first time: closing the viewer brings the screen back without reloading it.
            .task { if model.isLoading { await model.load() } }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.loadError, model.clusters.isEmpty {
            // Android shows "No duplicates found!" after a failed load, which would be misleading.
            ContentUnavailableView {
                Label("Couldn't Load Duplicates", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        } else if model.clusters.isEmpty {
            ContentUnavailableView {
                Label("No duplicates found!", systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        } else {
            VStack(spacing: 8) {
                DuplicatesHeader(
                    remaining: model.remainingCount,
                    progress: model.progress,
                    kept: model.keepCount,
                    deleted: model.deleteCount
                ) {
                    if model.deleteCount > 0 {
                        isConfirmingDelete = true
                    } else {
                        showsNoDeletions = true
                    }
                }
                .padding(.horizontal)

                clusterList
            }
            .safeAreaInset(edge: .bottom) {
                DuplicatesBottomBar(model: model) { order in
                    model.setSortOrder(order)
                    scrollTo(clusterIndex: model.firstUndecidedClusterIndex)
                } onAutoSelect: { mode in
                    // As on Android, ask first when that would touch groups the user has already sorted.
                    if model.decidedClusterCount > 0 {
                        pendingAutoSelect = mode
                    } else {
                        model.autoSelect(keepLargest: mode == .keepLargest)
                    }
                }
            }
            .alert("Apply to which groups?", isPresented: Binding(get: { pendingAutoSelect != nil }, set: { if !$0 { pendingAutoSelect = nil } }), presenting: pendingAutoSelect) { mode in
                Button("Replace all", role: .destructive) { model.autoSelect(keepLargest: mode == .keepLargest) }
                if model.decidedClusterCount < model.clusters.count {
                    Button("Only unsorted") { model.autoSelect(keepLargest: mode == .keepLargest, onlyUndecidedGroups: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(autoSelectMessage)
            }
        }
    }

    /// One card in the middle of the space above the bottom bar, snapping card by card. Cards further
    /// from that spot shrink to 82% and fade to 18%, as on Android.
    ///
    /// Android snaps a card's top to a padding worked out from an estimated card height, which centres
    /// it. Here the snap centres each card by its measured height, so cards of any height land in the
    /// middle. The geometry's height is the space above the bottom bar, which the list scrolls under.
    private var clusterList: some View {
        GeometryReader { geometry in
            let clearHeight = geometry.size.height
            // Android's estimate of a card's height (120 pt of header and buttons plus a 3:4 tile half the
            // card wide, at most 70% of the space), until the first and last cards have been measured.
            let tileWidth = (max(geometry.size.width - 64, 100) - 8) / 2
            let estimatedHeight = min(120 + tileWidth / 0.75, clearHeight * 0.7)
            // Room above the first card and below the last, so they can reach the middle too.
            let topPadding = max((clearHeight - (cardFrames[0]?.height ?? estimatedHeight)) / 2, 32)
            let bottomPadding = max((clearHeight - (cardFrames[model.visibleClusters.count - 1]?.height ?? estimatedHeight)) / 2, 32)

            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(Array(model.visibleClusters.enumerated()), id: \.element.id) { index, cluster in
                        DuplicateClusterCard(
                            cluster: cluster,
                            model: model,
                            contentWidth: geometry.size.width - 64,
                            peekingAssetID: peek?.asset.id,
                            onPeek: updatePeek,
                            onOpen: { assetIndex in
                                viewerClusterIndex = index
                                viewerStart = ViewerStart(clusterIndex: index, assetIndex: assetIndex)
                            }
                        )
                        .scrollTransition(axis: .vertical) { card, phase in
                            card
                                .scaleEffect(1 - 0.18 * abs(phase.value))
                                .opacity(1 - 0.82 * abs(phase.value))
                        }
                        // Measured outside the shrink effect, so it is the card's real place in the list.
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.listSpace)) } action: { frame in
                            cardFrames[index] = frame
                        }
                    }
                }
                // Padding inside the stack rather than content margins, so the stack's coordinates are
                // the scroll content's coordinates.
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
                .coordinateSpace(.named(Self.listSpace))
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(CenterSnapBehavior(cardFrames: Array(cardFrames.values), clearHeight: clearHeight))
            .scrollPosition($scrollPosition)
            .scrollIndicators(.hidden)
            // A pinch owns the fingers, as on Android, so the list doesn't scroll under it.
            .scrollDisabled(peek != nil)
        }
        // A reload, re-sort or filter moves every card, so the old measurements no longer apply.
        .onChange(of: model.visibleClusters.map(\.id)) { cardFrames = [:] }
        // Turning the filter on starts from the top of the shorter list, as on Android.
        .onChange(of: model.undecidedOnlyIDs != nil) { _, isFiltering in
            if isFiltering { scrollTo(clusterIndex: 0) }
        }
    }

    private static let listSpace = "duplicateClusters"

    /// Android's wording (`duplicates_autoselect_msg`, `duplicates_autoselect_all_msg`).
    private var autoSelectMessage: LocalizedStringKey {
        let decided = model.decidedClusterCount
        if decided == model.clusters.count { return "Every group already has choices. Replace them?" }
        if decided == 1 { return "1 group already has choices. Auto-select can leave it alone and only sort the rest, or replace its choices." }
        return "\(decided, format: .number) groups already have choices. Auto-select can leave them alone and only sort the rest, or replace their choices."
    }

    /// Follows a pinch, then lets the picture glide back into its tile before the overlay goes (Android:
    /// a spring with no bounce). A new pinch that starts during the glide keeps its overlay.
    private func updatePeek(_ new: DuplicatePeek) {
        if new.isActive {
            peek = new
        } else {
            peek?.isActive = false
            withAnimation(.smooth(duration: 0.35)) {
                peek?.scale = 1
                peek?.offset = .zero
            } completion: {
                if peek?.isActive == false { peek = nil }
            }
        }
    }

    private func scrollTo(clusterIndex: Int) {
        let clusters = model.visibleClusters
        guard clusters.indices.contains(clusterIndex) else { return }
        withAnimation(.smooth) {
            scrollPosition.scrollTo(id: clusters[clusterIndex].id, anchor: .center)
        }
    }

    private func scrollToViewerCluster() {
        scrollTo(clusterIndex: min(viewerClusterIndex, model.visibleClusters.count - 1))
    }
}

/// Ends every scroll with the nearest card centred in the space above the bottom bar. A fling still
/// travels as far as its speed takes it, then settles on the card nearest to where it would have stopped.
private struct CenterSnapBehavior: ScrollTargetBehavior {
    /// Cards that have been laid out, in scroll content coordinates.
    let cardFrames: [CGRect]
    let clearHeight: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard !cardFrames.isEmpty else { return }
        let middle = target.rect.minY + clearHeight / 2
        guard let nearest = cardFrames.min(by: { abs($0.midY - middle) < abs($1.midY - middle) }) else { return }
        // A long fling can stop beyond the cards the lazy list has laid out. From the nearest measured
        // card, step on by whole cards of the average measured height.
        let stride = cardFrames.reduce(0) { $0 + $1.height } / CGFloat(cardFrames.count) + 16
        let steps = ((middle - nearest.midY) / stride).rounded()
        target.rect.origin.y = nearest.midY + steps * stride - clearHeight / 2
    }
}

// MARK: - Header

/// The pill (what's left, the progress bar, the percentage) and the Keep and Delete counts.
/// Android draws its own gradient bar; this uses the swipe screen's glass pill.
private struct DuplicatesHeader: View {
    let remaining: Int
    let progress: Double
    let kept: Int
    let deleted: Int
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onTap) {
                // The same pill as the swipe screen: ring and "N left", deleted and kept counts, list icon.
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ProgressRing(progress: progress)
                            .frame(width: 22, height: 22)

                        Text("\(remaining) left")
                            .font(.footnote.bold())
                            .monospacedDigit()
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    PillCount(value: deleted, systemImage: "trash.fill", color: .red)
                        .padding(.trailing, 10)
                    PillCount(value: kept, systemImage: "checkmark.circle.fill", color: .green)
                        .padding(.trailing, 12)

                    Image(systemName: "list.bullet")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .frame(height: 44)
                .contentShape(.capsule)
                .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete Marked Duplicates")
            .accessibilityValue(Text("\(remaining, format: .number) left, \(deleted, format: .number) delete, \(kept, format: .number) keep"))
            .animation(.snappy, value: remaining)
        }
    }

    /// A determinate circular progress indicator, as on the swipe screen.
    private struct ProgressRing: View {
        let progress: Double

        var body: some View {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(1.5)
            .animation(.smooth, value: progress)
        }
    }

    private struct PillCount: View {
        let value: Int
        let systemImage: String
        let color: Color

        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.footnote)
                    .foregroundStyle(color)
                Text(value, format: .number)
                    .font(.caption.bold())
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .fixedSize()
            .animation(.snappy, value: value)
        }
    }
}

// MARK: - Bottom bar

/// Sort (an icon showing the current order), the "Only undecided groups" filter, and Select (the last
/// auto-select applied, or "Select"). Android's Select menu also has four Best Shot modes, which are not
/// ported yet.
private struct DuplicatesBottomBar: View {
    let model: DuplicatesModel
    let onSort: (DuplicatesModel.SortOrder) -> Void
    let onAutoSelect: (DuplicatesModel.AutoSelectMode) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(DuplicatesModel.SortOrder.allCases, id: \.self) { order in
                    Button { onSort(order) } label: {
                        Label(Self.title(of: order), systemImage: model.sortOrder == order ? "checkmark" : Self.symbol(of: order))
                    }
                }
            } label: {
                Label("Sort", systemImage: Self.symbol(of: model.sortOrder))
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)

            UndecidedOnlyButton(model: model)

            Menu {
                Button { onAutoSelect(.keepLargest) } label: {
                    Label("Keep largest", systemImage: model.autoSelectMode == .keepLargest ? "checkmark" : "chevron.down")
                }
                Button { onAutoSelect(.keepSmallest) } label: {
                    Label("Keep smallest", systemImage: model.autoSelectMode == .keepSmallest ? "checkmark" : "chevron.up")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text(selectTitle).bold()
                    Image(systemName: "chevron.down")
                        .font(.caption.bold())
                }
                // Wide enough for the longest title, so the button doesn't change size between modes.
                .frame(minWidth: 140, minHeight: 32)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var selectTitle: LocalizedStringKey {
        switch model.autoSelectMode {
        case .keepLargest: "Largest"
        case .keepSmallest: "Smallest"
        case nil: "Select"
        }
    }

    private static func title(of order: DuplicatesModel.SortOrder) -> LocalizedStringKey {
        switch order {
        case .clusterSize: "Cluster size"
        case .photosFirst: "Photos first"
        case .videosFirst: "Videos first"
        }
    }

    private static func symbol(of order: DuplicatesModel.SortOrder) -> String {
        switch order {
        case .clusterSize: "arrow.up.arrow.down"
        case .photosFirst: "photo"
        case .videosFirst: "video"
        }
    }
}

/// "Only undecided groups" (Android's filter toggle). Tinted glass while on. It can't be turned on when
/// nothing is left to sort, as on Android.
private struct UndecidedOnlyButton: View {
    let model: DuplicatesModel

    var body: some View {
        let isOn = model.undecidedOnlyIDs != nil
        Group {
            if isOn {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.glass)
            }
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(!isOn && model.remainingCount == 0)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var button: some View {
        Button { model.toggleUndecidedOnly() } label: {
            Label("Only undecided groups", systemImage: "line.3.horizontal.decrease")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 32, height: 32)
        }
    }
}

/// "Syncing…" over a dimmed screen while the delete runs. It can't be dismissed, as on Android.
private struct SyncingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            HStack(spacing: 16) {
                ProgressView()
                Text("Syncing…")
            }
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }
}
