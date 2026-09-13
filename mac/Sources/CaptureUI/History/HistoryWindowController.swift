import AppKit
import CaptureCore
import CaptureHistory
import SwiftUI

/// Backs the searchable local-evidence History browser (Part I §28
/// "History — searchable local evidence", §25 "recent captures; ...OCR
/// search; domain/URL search; date; tags; favourites"), driven by the real
/// `CaptureHistory.HistoryStore.search`/`.recentCaptures` API.
@MainActor
final class HistoryBrowserModel: ObservableObject {
    @Published var query: String = "" { didSet { scheduleSearch() } }
    @Published var favouritesOnly: Bool = false { didSet { scheduleSearch() } }
    @Published var entries: [HistoryEntry] = []
    @Published var isLoading = false

    private let historyStore: HistoryStore
    private var searchTask: Task<Void, Never>?

    init(historyStore: HistoryStore) {
        self.historyStore = historyStore
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let currentQuery = query
        let currentFavouritesOnly = favouritesOnly
        isLoading = true
        searchTask = Task.detached(priority: .userInitiated) { [historyStore] in
            let filters = HistorySearchFilters(favouriteOnly: currentFavouritesOnly)
            let results: [HistoryEntry]
            do {
                results = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? try historyStore.recentCaptures(limit: 200)
                    : try historyStore.search(query: currentQuery, filters: filters)
            } catch {
                results = []
            }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.entries = results
                self.isLoading = false
            }
        }
    }

    func toggleFavourite(_ entry: HistoryEntry) {
        Task.detached { [historyStore] in try? historyStore.setFavourite(!entry.favourite, forCapture: entry.id) }
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) { entries[idx].favourite.toggle() }
    }

    func delete(_ entry: HistoryEntry) {
        Task.detached { [historyStore] in try? historyStore.deleteCapture(id: entry.id) }
        entries.removeAll { $0.id == entry.id }
    }
}

@MainActor
public final class HistoryWindowController: NSWindowController {
    private let model: HistoryBrowserModel

    /// `CaptureUI` cannot itself locate the pixels/`.capture` package for a
    /// `HistoryEntry` (see `EditorWindowController`'s doc comment / this
    /// module's final report on the missing blob-path field) — opening an
    /// entry is delegated back to `CaptureApp`, which owns the
    /// content-addressed blob store this needs.
    public init(historyStore: HistoryStore, onOpen: @escaping (HistoryEntry) -> Void) {
        self.model = HistoryBrowserModel(historyStore: historyStore)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "History"
        window.center()
        super.init(window: window)
        let view = HistoryBrowserView(model: model, onOpen: onOpen, onDelete: { [model] entry in model.delete(entry) }, onToggleFavourite: { [model] entry in model.toggleFavourite(entry) })
        window.contentView = NSHostingView(rootView: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct HistoryBrowserView: View {
    @ObservedObject var model: HistoryBrowserModel
    let onOpen: (HistoryEntry) -> Void
    let onDelete: (HistoryEntry) -> Void
    let onToggleFavourite: (HistoryEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.captureTextSecondary)
                TextField("Search history — OCR text, URL, domain, tags…", text: $model.query)
                    .textFieldStyle(.plain)
                Toggle(isOn: $model.favouritesOnly) {
                    Image(systemName: model.favouritesOnly ? "star.fill" : "star")
                }
                .toggleStyle(.button)
                .tint(.captureAmber)
            }
            .padding(10)
            .background(Color.capturePanelBackground)

            Divider().background(Color.captureSeparator)

            if model.entries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 28)).foregroundStyle(Color.captureTextSecondary)
                    Text(model.isLoading ? "Searching…" : "No captures found").foregroundStyle(Color.captureTextSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.entries) { entry in
                        HistoryRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onOpen(entry) }
                            .contextMenu {
                                Button("Open") { onOpen(entry) }
                                Button(entry.favourite ? "Remove from Favourites" : "Add to Favourites") { onToggleFavourite(entry) }
                                Divider()
                                Button("Remove from History", role: .destructive) { onDelete(entry) }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Color.captureCanvasBackground)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.capturePanelBackground)
                .frame(width: 56, height: 40)
                .overlay(Image(systemName: iconName).foregroundStyle(Color.captureSemantic(.capture)))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.pageTitle ?? entry.sourceApp ?? "Capture")
                    .font(CaptureFont.body())
                    .foregroundStyle(Color.captureTextPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.captureDate, style: .date).font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                    if let domain = entry.domain {
                        Text("· \(domain)").font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                    }
                    Text("· \(Int(entry.dimensions.width))×\(Int(entry.dimensions.height))").font(CaptureFont.secondary()).foregroundStyle(Color.captureTextSecondary)
                }
            }

            Spacer()

            if entry.privacyStatus != .unreviewed {
                Image(systemName: "eye.slash.fill").foregroundStyle(Color.captureSemantic(.privacy)).help(entry.privacyStatus.rawValue)
            }
            if entry.favourite {
                Image(systemName: "star.fill").foregroundStyle(Color.captureAmber)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch entry.captureType {
        case .screenshot: return "photo"
        case .recording: return "video"
        case .assembly: return "square.grid.2x2"
        }
    }
}
