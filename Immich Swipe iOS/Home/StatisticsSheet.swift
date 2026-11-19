import SwiftUI

/// The Android app's "Usage Statistics" popup (`StatsPopup.kt`): totals from the apply history, this
/// week's slice of it, and how decisions split between keep, delete, archive and lock.
struct StatisticsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let decisions: DecisionStore
    let userID: String
    let totalAlbums: Int
    let completedAlbums: Int

    @State private var stats = Stats()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Global Statistics").font(.headline)

                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            StatCard(title: "Deleted", value: stats.totalDeleted.formatted(), systemImage: "trash", color: .red)
                            StatCard(title: "Space freed", value: Self.size(stats.totalBytesSaved), systemImage: "checkmark.icloud", color: .green)
                        }
                        GridRow {
                            StatCard(title: "Photos sorted", value: stats.totalSwiped.formatted(), systemImage: "hand.draw", color: .accentColor)
                            StatCard(title: "Albums finished", value: "\(completedAlbums) / \(totalAlbums)", systemImage: "checklist", color: .teal)
                        }
                    }

                    Text("This week").font(.headline).padding(.top, 12)

                    HStack {
                        WeeklyFigure(title: "Deleted", value: stats.weeklyDeleted.formatted())
                        Divider().frame(height: 40)
                        WeeklyFigure(title: "Space freed", value: Self.size(stats.weeklyBytesSaved))
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))

                    Text("Decision breakdown").font(.headline).padding(.top, 20)

                    if stats.totalSwiped == 0 {
                        Text("No synchronization data available yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 12) {
                            DistributionBar(title: "Keep", fraction: stats.fraction(stats.totalKept), color: .green)
                            DistributionBar(title: "Delete", fraction: stats.fraction(stats.totalDeleted), color: .red)
                            DistributionBar(title: "Archive", fraction: stats.fraction(stats.totalArchived), color: .orange)
                            DistributionBar(title: "Locked", fraction: stats.fraction(stats.totalLocked), color: .purple)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Usage Statistics")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .task { stats = await Stats(decisions: decisions, userID: userID) }
        }
    }

    /// Android's `formatSize`: at most three digits, in KB, MB, GB or TB. The decimals taper off as the
    /// number grows, and it steps up a unit once the number would round to four digits.
    nonisolated static func size(_ bytes: Int64) -> String {
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 999.5, unit < 3 {
            value /= 1024
            unit += 1
        }
        let decimals = unit == 0 || value >= 99.95 ? 0 : value >= 9.995 ? 1 : 2
        let number = value.formatted(.number.precision(.fractionLength(decimals)))
        switch unit {
        case 0: return String(localized: "\(number) KB")
        case 1: return String(localized: "\(number) MB")
        case 2: return String(localized: "\(number) GB")
        default: return String(localized: "\(number) TB")
        }
    }

    /// The same sums as Android's `HomeViewModel`. Deleted and locked only count what has been applied.
    /// Kept and archived photos keep their decision after an apply, so those decisions are counted
    /// instead of the history, which would count them again on every apply.
    struct Stats {
        var totalDeleted = 0
        var totalBytesSaved: Int64 = 0
        var totalKept = 0
        var totalArchived = 0
        var totalLocked = 0
        var weeklyDeleted = 0
        var weeklyBytesSaved: Int64 = 0

        var totalSwiped: Int { totalDeleted + totalKept + totalArchived + totalLocked }

        func fraction(_ count: Int) -> Double {
            totalSwiped == 0 ? 0 : Double(count) / Double(totalSwiped)
        }

        init() {}

        /// Every decision is read off the main thread: with tens of thousands it takes about half a second.
        init(decisions: DecisionStore, userID: String) async {
            let history = (try? decisions.syncHistory(userID: userID)) ?? []
            let all = ((try? await decisions.allDecisionsInBackground(userID: userID)) ?? [:]).values
            let weekAgo = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
            let week = history.filter { $0.timestamp >= weekAgo }

            totalDeleted = history.reduce(0) { $0 + $1.deletedCount }
            totalBytesSaved = history.reduce(0) { $0 + $1.bytesSaved }
            totalLocked = history.reduce(0) { $0 + $1.lockedCount }
            totalKept = all.count { $0.decision == .keep }
            totalArchived = all.count { $0.decision == .archive }
            weeklyDeleted = week.reduce(0) { $0 + $1.deletedCount }
            weeklyBytesSaved = week.reduce(0) { $0 + $1.bytesSaved }
        }
    }
}

private struct StatCard: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.title3)
            Text(value).font(.title2.weight(.black))
            Text(title).font(.caption).opacity(0.8)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(color.opacity(0.1), in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 0.5) }
    }
}

private struct WeeklyFigure: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack {
            Text(value).font(.title2.weight(.bold))
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DistributionBar: View {
    let title: LocalizedStringKey
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(0))).fontWeight(.bold)
            }
            .font(.subheadline)
            ProgressView(value: fraction)
                .tint(color)
        }
    }
}
