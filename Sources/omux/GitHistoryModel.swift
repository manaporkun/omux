import Foundation
import Combine

@MainActor
final class GitHistoryModel: ObservableObject {
    @Published private(set) var snapshot: HistorySnapshot?
    @Published private(set) var rows: [GitGraphRow] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var selectedID: String?
    @Published private(set) var detail: HistoryDetail?
    @Published private(set) var detailLoading = false
    @Published private(set) var detailError: String?
    @Published private(set) var limit = 200
    @Published var allBranches = true
    private(set) var directory: String?
    private var generation = UUID()
    private var again = false
    private var watchers: [FolderWatcher] = []
    private var watchedPaths: [String] = []
    private var timer: Task<Void, Never>?

    var selected: HistoryCommit? { snapshot?.commits.first { $0.id == selectedID } }

    func track(_ directory: String?) {
        stop()
        self.directory = directory
        snapshot = nil; rows = []; error = nil; selectedID = nil; detail = nil; detailError = nil
        limit = 200
        guard directory != nil else { return }
        refresh()
        // Fallback for missed filesystem events and repositories created after opening the panel.
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        directory = nil
        generation = UUID()
        timer?.cancel(); timer = nil
        watchers = []; watchedPaths = []
        loading = false; detailLoading = false; again = false
    }

    func loadMore() {
        guard limit < 2000 else { return }
        limit = min(2000, limit + 200)
        refresh()
    }

    func refresh() {
        guard let directory else { return }
        if loading { again = true; return }
        loading = true
        let token = generation, count = limit, all = allBranches
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { () -> (HistorySnapshot, [GitGraphRow]) in
                    let snapshot = try GitHistory.read(directory, limit: count, allBranches: all)
                    return (snapshot, GitGraphLayout.rows(snapshot.commits))
                }
            }.value
            guard generation == token else { return }
            loading = false
            switch result {
            case .success(let (value, graph)):
                error = nil
                if snapshot != value { snapshot = value; rows = graph }
                if watchedPaths != value.watchPaths {
                    watchedPaths = value.watchPaths
                    watchers = value.watchPaths.map { path in FolderWatcher(path: path) { [weak self] in self?.refresh() } }
                }
                let retained = value.commits.first { $0.id == selectedID }?.id
                let next = retained ?? value.commits.first(where: { $0.id == value.head })?.id ?? value.commits.first?.id
                if next != selectedID || (detail == nil && !detailLoading && detailError == nil) {
                    if let next { select(next) }
                    else { selectedID = nil; detail = nil; detailError = nil }
                }
            case .failure(let failure): error = failure.localizedDescription
            }
            if again { again = false; refresh() }
        }
    }

    func moveSelection(_ offset: Int) {
        guard let commits = snapshot?.commits, !commits.isEmpty else { return }
        let index = commits.firstIndex { $0.id == selectedID } ?? 0
        select(commits[max(0, min(commits.count - 1, index + offset))].id)
    }

    func select(_ id: String) {
        guard let commit = snapshot?.commits.first(where: { $0.id == id }), let directory else { return }
        selectedID = id
        detail = nil; detailError = nil; detailLoading = true
        let token = generation
        Task {
            let result = await Task.detached(priority: .utility) { Result { try GitHistory.detail(commit, directory: directory) } }.value
            guard generation == token, selectedID == id else { return }
            detailLoading = false
            switch result {
            case .success(let value): detail = value
            case .failure(let failure): detailError = failure.localizedDescription
            }
        }
    }
}
