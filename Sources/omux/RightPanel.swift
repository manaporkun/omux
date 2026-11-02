import SwiftUI

enum PanelTab: String, CaseIterable {
    case files, changes, browser, history
}

/// The right panel: Files, Changes and Browser for the selected session.
struct RightPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var changes = Changes.shared
    let root: URL
    let theme: Theme
    @AppStorage(Prefs.panelTab) private var tab = PanelTab.files.rawValue

    private var current: PanelTab { PanelTab(rawValue: tab) ?? .files }

    private var historyDirectory: String? {
        guard let group = store.selectedGroup else { return nil }
        if let tab = store.selectedTab, group.tabs.contains(where: { $0.id == tab.id }) {
            return store.directory(of: tab).map { ($0 as NSString).expandingTildeInPath }
        }
        return group.directory.map { ($0 as NSString).expandingTildeInPath }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                tabs(compact: false).fixedSize(horizontal: true, vertical: false)
                tabs(compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(Color(nsColor: theme.chrome))
            // A real hairline rather than an overlay: the split views below extend into any safe
            // area they touch, and the tab bar sits in the title bar's. The hairline keeps them apart.
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)

            ZStack(alignment: .topLeading) {
                // Files stays alive so its preview and scroll position survive tab switches.
                FilePanel(root: root, theme: theme)
                    .opacity(current == .files ? 1 : 0)
                    .allowsHitTesting(current == .files)
                    .accessibilityHidden(current != .files)
                if current == .changes {
                    ChangesPanel(theme: theme)
                }
                if current == .history {
                    GitHistoryPanel(directory: historyDirectory, theme: theme)
                }
                if current == .browser {
                    if let id = store.selectedTabID {
                        BrowserPanel(session: store.browser(for: id), theme: theme).id(id)
                    } else {
                        Text("No session").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func tabs(compact: Bool) -> some View {
        HStack(spacing: 2) {
            button(.files, "Files", "doc", shortcut: "1", compact: compact)
            button(.changes, "Changes", "plusminus", shortcut: "2",
                   badge: changes.tabID == store.selectedTabID ? changes.files.count : 0, compact: compact)
            button(.browser, "Browser", "globe", shortcut: "3", compact: compact)
            button(.history, "History", "arrow.triangle.branch", shortcut: "4", compact: compact)
            Spacer(minLength: 0)
        }
    }

    private func button(_ value: PanelTab, _ title: String, _ icon: String, shortcut: String, badge: Int = 0, compact: Bool = false) -> some View {
        let selected = current == value
        return Button { tab = value.rawValue } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).imageScale(.small)
                if !compact { Text(title).lineLimit(1) }
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 14)
                        .background(.primary.opacity(0.14), in: Capsule())
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) (⌥⌘\(shortcut))")
        .accessibilityLabel(title)
    }
}
