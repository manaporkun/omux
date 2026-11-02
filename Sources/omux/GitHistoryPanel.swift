import AppKit
import SwiftUI

struct GitHistoryPanel: View {
    @EnvironmentObject private var store: Store
    @StateObject private var model = GitHistoryModel()
    @FocusState private var historyFocused: Bool
    let directory: String?
    let theme: Theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.rows.isEmpty {
                Divider()
                HStack {
                    Text("\(model.rows.count) commits · Read-only").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if model.snapshot?.hasMore == true {
                        if model.limit < 2000 {
                            Button("Load more") { model.loadMore() }.disabled(model.loading).font(.caption)
                        } else { Text("Latest 2,000 · Narrow the scope").font(.caption2).foregroundStyle(.secondary) }
                    }
                }.padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: theme.background))
        .coordinateSpace(name: "gitHistoryPanel")
        #if DEBUG
        .background(HistoryPanelAnchor().allowsHitTesting(false))
        .onAppear { GitHistoryChecks.model = model }
        .onPreferenceChange(HistoryRowFrames.self) { GitHistoryChecks.frames = $0 }
        #endif
        .task(id: directory) { model.track(directory) }
        .onChange(of: model.allBranches) { _, _ in model.refresh() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if directory == nil {
            emptyState("Choose a repository", icon: "folder", message: "Open a project folder containing a Git repository to see its history.", canOpenFolder: true)
        } else if let snapshot = model.snapshot {
            if snapshot.root == nil {
                emptyState("No Git history here", icon: "folder", message: "This project folder isn’t a Git repository. Open a repository folder to view its commits.", canOpenFolder: true)
            } else if snapshot.commits.isEmpty {
                emptyState("No commits yet", icon: "arrow.triangle.branch", message: model.allBranches
                    ? "Your commit history will appear after the first commit."
                    : "There are no commits in this checkout’s ancestry. Try All branches to inspect the rest of the repository.")
            } else {
                VSplitView {
                    history.frame(minHeight: 140, idealHeight: 340)
                    details.frame(minHeight: 140, idealHeight: 260)
                }
            }
        } else if model.error != nil {
            emptyState("History unavailable", icon: "exclamationmark.triangle", message: "Check the folder and repository access, then try refreshing.")
        } else {
            ProgressView("Loading local history…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyState(_ title: String, icon: String, message: String, canOpenFolder: Bool = false) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                .frame(width: 48, height: 48)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if canOpenFolder {
                Button("Open project folder…") { store.openFolderPanel() }
                    .buttonStyle(.bordered).controlSize(.regular).padding(.top, 4)
            }
        }
        .frame(maxWidth: 280).padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Git History", systemImage: "arrow.triangle.branch").font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.loading { ProgressView().controlSize(.mini) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).disabled(model.loading).help("Refresh local history")
            }
            if !model.rows.isEmpty || (model.snapshot?.root != nil && !model.allBranches) {
                Picker("History scope", selection: $model.allBranches) {
                    Text("All branches").tag(true)
                    Text("HEAD ancestry").tag(false)
                }.pickerStyle(.segmented).labelsHidden()
            }
            if let snapshot = model.snapshot, snapshot.root != nil {
                Text(snapshot.headLabel)
                    .font(.caption).lineLimit(1).help(snapshot.head ?? "No HEAD commit")
            }
            Text(model.snapshot?.root ?? directory ?? "No folder")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(model.snapshot?.root ?? directory ?? "No folder")
        }.padding(10).background(Color(nsColor: theme.chrome))
    }

    private var history: some View {
        GeometryReader { geometry in
            let graphWidth = CGFloat(model.rows.map(\.width).max() ?? 1) * 16 + 16
            let scrollbar = CGFloat(model.rows.count) * 44 > geometry.size.height
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle) : 0
            let width = max(geometry.size.width - scrollbar, graphWidth + 180)
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            commitRow(row, width: width, graphWidth: graphWidth)
                        }
                    }
                }
                .focusable().focused($historyFocused)
                .onMoveCommand { direction in
                    if direction == .up || direction == .down {
                        model.moveSelection(direction == .up ? -1 : 1)
                        if let id = model.selectedID { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    private func commitRow(_ row: GitGraphRow, width: CGFloat, graphWidth: CGFloat) -> some View {
        Button { model.select(row.id); historyFocused = true } label: {
            HStack(spacing: 8) {
                CommitLanes(row: row, isHead: row.id == model.snapshot?.head)
                    .frame(width: graphWidth, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if row.id == model.snapshot?.head {
                            Text("HEAD").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.accentColor)
                        }
                        Text(row.commit.subject).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    Text(row.commit.references.isEmpty
                         ? "\(row.id.prefix(8)) · \(row.commit.author)"
                         : row.commit.references.map(\.label).joined(separator: " · "))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 8)
            .frame(width: width, height: 44).contentShape(Rectangle())
            .background(model.selectedID == row.id ? Color.accentColor.opacity(0.14) : .clear)
        }
        .buttonStyle(.plain).id(row.id)
        .accessibilityAddTraits(model.selectedID == row.id ? [.isSelected] : [])
        .help("\(row.commit.subject)\n\(row.commit.author) · \(row.commit.date.formatted())\n\(row.commit.references.map(\.label).joined(separator: ", "))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.id == model.snapshot?.head ? "HEAD, " : "")\(row.commit.subject), \(row.commit.author), \(row.commit.parents.count) parents, \(row.commit.references.map(\.label).joined(separator: ", "))")
        #if DEBUG
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: HistoryRowFrames.self, value: [row.id: geometry.frame(in: .global)])
            }
        }
        #endif
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let commit = model.selected {
                    Text(commit.subject).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(commit.id).font(.caption.monospaced()).textSelection(.enabled)
                    Text("\(commit.author) <\(commit.email)>\n\(commit.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if !commit.references.isEmpty {
                        Text(commit.references.map(\.label).joined(separator: " · ")).font(.caption).foregroundStyle(Color.accentColor).textSelection(.enabled)
                    }
                    if !commit.parents.isEmpty {
                        Text("Parents: " + commit.parents.map { String($0.prefix(10)) }.joined(separator: ", "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if model.detailLoading { ProgressView().controlSize(.small) }
                    if let error = model.detailError { Text(error).font(.caption).foregroundStyle(.red) }
                    if let detail = model.detail {
                        Text(detail.message).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Text(commit.parents.isEmpty ? "Files at history root" : "Changed files · Compared with first parent")
                            .font(.caption).foregroundStyle(.secondary)
                        if detail.files.isEmpty { Text("No file changes").font(.caption).foregroundStyle(.secondary) }
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(detail.files) { file in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(file.status).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 18)
                                    Text(file.path).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if detail.truncated { Text("Large commit: message or file list truncated.").font(.caption2).foregroundStyle(.secondary) }
                    }
                } else { Text("Select a commit to inspect it.").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}

private struct CommitLanes: View {
    let row: GitGraphRow
    let isHead: Bool
    private let colors: [Color] = [.blue, .purple, .teal, .pink, .indigo, .green, .orange, .cyan]

    var body: some View {
        Canvas { context, size in
            let center = size.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane) * 16 + 10 }
            for track in row.incoming {
                var path = Path()
                path.move(to: CGPoint(x: x(track.lane), y: 0))
                path.addLine(to: CGPoint(x: x(track.lane), y: center))
                context.stroke(path, with: .color(colors[track.color % colors.count]), lineWidth: 1.5)
            }
            for edge in row.outgoing {
                var path = Path()
                path.move(to: CGPoint(x: x(edge.from), y: center))
                path.addCurve(to: CGPoint(x: x(edge.to), y: size.height),
                              control1: CGPoint(x: x(edge.from), y: center + 8),
                              control2: CGPoint(x: x(edge.to), y: size.height - 8))
                context.stroke(path, with: .color(colors[edge.color % colors.count]), lineWidth: 1.5)
            }
            let point = CGPoint(x: x(row.lane), y: center)
            let dot = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(colors[row.color % colors.count]))
            if isHead || row.commit.parents.count > 1 {
                context.stroke(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                               with: .color(colors[row.color % colors.count]), lineWidth: 1.5)
            }
        }
    }
}

#if DEBUG
struct HistoryRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct HistoryPanelAnchor: NSViewRepresentable {
    final class Anchor: NSView { override var isFlipped: Bool { true } }
    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        GitHistoryChecks.anchor = view
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
