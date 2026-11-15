import SwiftUI

/// "System Logs", from Android's `LogsScreen` and `LogsDialog`: the log file with errors in red and
/// warnings in orange, opened at the newest entry, with Clear and Copy All.
struct LogsView: View {
    /// Nil while loading.
    @State private var logs: LoadedLogs?
    @State private var reloadKey = 0
    @State private var showsCopied = false

    var body: some View {
        content
            .navigationTitle("System Logs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: logs?.raw ?? "")
                        .disabled(isEmpty)
                }
                ToolbarItem(placement: Self.actionsPlacement) {
                    Button("Clear Logs", role: .destructive) {
                        AppLog.file.clear()
                        reloadKey += 1
                    }
                    .disabled(isEmpty)
                }
                ToolbarSpacer(.flexible, placement: Self.actionsPlacement)
                ToolbarItem(placement: Self.actionsPlacement) {
                    Button("Copy All") { copy() }
                        .disabled(isEmpty)
                }
            }
            // Android shows a toast.
            .overlay(alignment: .top) {
                if showsCopied {
                    Label("Logs copied to clipboard", systemImage: "doc.on.doc")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: showsCopied)
            .task(id: showsCopied) {
                guard showsCopied else { return }
                try? await Task.sleep(for: .seconds(2))
                showsCopied = false
            }
            .sensoryFeedback(.success, trigger: showsCopied) { _, new in new }
            .task(id: reloadKey) { logs = await LoadedLogs.load() }
    }

    @ViewBuilder
    private var content: some View {
        if let logs {
            if logs.lines.isEmpty {
                ContentUnavailableView("No Logs", systemImage: "doc.text", description: Text("No logs available at the moment."))
            } else {
                // Only the visible lines are laid out, so a full 2 MB log still opens quickly.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(logs.lines) { line in
                            Text(line.text)
                                .foregroundStyle(line.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.caption2.monospaced())
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isEmpty: Bool { logs?.lines.isEmpty ?? true }

    private static var actionsPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .bottomBar
        #else
        .automatic
        #endif
    }

    private func copy() {
        guard let raw = logs?.raw else { return }
        #if os(iOS)
        UIPasteboard.general.string = raw
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
        #endif
        showsCopied = true
    }
}

/// The log text and its lines, read off the main thread since the files can reach about 2 MB.
private nonisolated struct LoadedLogs: Sendable {
    struct Line: Identifiable, Sendable {
        let id: Int
        let text: String

        /// Android colours lines by level: ` E/` red, ` W/` orange.
        var color: Color {
            if text.contains(" E/") { .red } else if text.contains(" W/") { .orange } else { .primary }
        }
    }

    let raw: String
    let lines: [Line]

    @concurrent
    static func load() async -> LoadedLogs {
        let raw = AppLog.file.contents()
        let lines = raw.isEmpty ? [] : raw.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { Line(id: $0.offset, text: String($0.element)) }
        return LoadedLogs(raw: raw, lines: lines)
    }
}

#Preview {
    NavigationStack {
        LogsView()
    }
}
