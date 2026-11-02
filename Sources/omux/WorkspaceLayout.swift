import Foundation

/// UI state is independent of provider conversations and terminal processes.
struct CanvasWorkspace: Codable, Equatable {
    var projectID: UUID?
    var maximizedID: UUID?
    var projects: [UUID: ProjectCanvas] = [:]
    var pinnedProjects: Set<UUID> = []
    var projectOrder: [UUID]?

    func orderedProjects(_ groups: [TabGroup]) -> [TabGroup] {
        let ranks = Dictionary((projectOrder ?? []).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return groups.sorted {
            let a = pinnedProjects.contains($0.id), b = pinnedProjects.contains($1.id)
            if a != b { return a }
            let ar = ranks[$0.id] ?? Int.max, br = ranks[$1.id] ?? Int.max
            if ar != br { return ar < br }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    /// Reorder visible slots only; filtering must not move hidden projects.
    mutating func moveProject(_ source: UUID, before target: UUID?, visibleProjects: [UUID], groups: [TabGroup]) -> Bool {
        let ordered = orderedProjects(groups).map(\.id)
        let visible = Set(visibleProjects)
        let pinned = pinnedProjects.contains(source)
        let slots = ordered.indices.filter { visible.contains(ordered[$0]) && pinnedProjects.contains(ordered[$0]) == pinned }
        var moving = slots.map { ordered[$0] }
        guard let from = moving.firstIndex(of: source), source != target else { return false }
        if let target, !moving.contains(target) { return false }
        moving.remove(at: from)
        let destination = target.flatMap { moving.firstIndex(of: $0) } ?? moving.endIndex
        moving.insert(source, at: destination)
        var result = ordered
        for (slot, id) in zip(slots, moving) { result[slot] = id }
        guard result != ordered else { return false }
        projectOrder = result
        return true
    }

    func project(_ id: UUID) -> ProjectCanvas { projects[id] ?? ProjectCanvas() }

    mutating func reconcile(groups: [TabGroup]) {
        let groupIDs = Set(groups.map(\.id))
        let tabIDs = Set(groups.flatMap { $0.tabs.map(\.id) })
        if let id = projectID, !groupIDs.contains(id) { projectID = groups.first?.id }
        if let id = maximizedID, !tabIDs.contains(id) { maximizedID = nil }
        pinnedProjects.formIntersection(groupIDs)
        projectOrder = projectOrder?.filter { groupIDs.contains($0) }
        projects = projects.filter { groupIDs.contains($0.key) }
        for group in groups where projects[group.id] != nil {
            projects[group.id]?.minimized.formIntersection(Set(group.tabs.map(\.id)))
        }
    }
}

struct ProjectCanvas: Codable, Equatable {
    var minimized: Set<UUID> = []

    init(minimized: Set<UUID> = []) { self.minimized = minimized }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        minimized = try values.decodeIfPresent(Set<UUID>.self, forKey: .minimized) ?? []
        // Legacy size overrides are intentionally ignored: terminal sizing is automatic.
    }
}

/// Chooses the largest readable landscape windows that fit; otherwise scrolls vertically.
struct TerminalGridLayout: Equatable {
    let columns: Int
    let width: CGFloat
    let height: CGFloat
    static let gap: CGFloat = 12
    static let minimum = CGSize(width: 300, height: 170)

    init(count: Int, available: CGSize) {
        let count = max(1, count)
        let availableWidth = max(Self.minimum.width, available.width)
        let availableHeight = max(0, available.height)
        let maxColumns = min(count, max(1, Int((availableWidth + Self.gap) / (Self.minimum.width + Self.gap))))
        var best: (columns: Int, width: CGFloat, height: CGFloat, area: CGFloat)?
        for columns in 1...maxColumns {
            let width = (availableWidth - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)
            let rows = Int(ceil(Double(count) / Double(columns)))
            let minimumHeight = max(Self.minimum.height, width / 2.8)
            let height = min(width / 1.3, (availableHeight - CGFloat(rows - 1) * Self.gap) / CGFloat(rows))
            guard height >= minimumHeight else { continue }
            let area = width * height
            if best == nil || area > best!.area { best = (columns, width, height, area) }
        }
        if let best {
            columns = best.columns; width = best.width; height = floor(best.height)
        } else {
            columns = maxColumns
            width = (availableWidth - CGFloat(maxColumns - 1) * Self.gap) / CGFloat(maxColumns)
            height = ceil(max(Self.minimum.height, width / 2.8))
        }
    }
}

enum CanvasSessionState: String, CaseIterable {
    case working, needsYou, idle, error, running, ended, interrupted
    var label: String {
        switch self {
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .idle: return "Idle"
        case .error: return "Error"
        case .running: return "Running"
        case .ended: return "Ended"
        case .interrupted: return "Interrupted"
        }
    }
    var needsAttention: Bool { self == .needsYou || self == .error || self == .interrupted }

    init(_ runtime: TabRuntime) {
        if runtime.interrupted { self = .interrupted }
        else if runtime.statusState == .error { self = .error }
        else if runtime.exited { self = .ended }
        else if runtime.statusState == .blocked { self = .needsYou }
        else if runtime.statusState == .working { self = .working }
        else if runtime.statusState == .done || runtime.statusState == .idle { self = .idle }
        else if runtime.busy { self = runtime.provider == .shell || runtime.provider == .custom ? .running : .working }
        else { self = .idle }
    }
}

enum CanvasFilter: String, CaseIterable, Identifiable {
    case all, needsYou, working, idle
    var id: String { rawValue }
    var label: String {
        switch self { case .all: return "All"; case .needsYou: return "Needs you"; case .working: return "Working"; case .idle: return "Idle" }
    }
    func includes(_ state: CanvasSessionState) -> Bool {
        switch self {
        case .all: return true
        case .needsYou: return state.needsAttention
        case .working: return state == .working || state == .running
        case .idle: return state == .idle || state == .ended
        }
    }
}

/// Filter matches are partitioned without hiding unrelated shelf entries.
struct CanvasFilterResult {
    let visible: [TabItem]
    let shelf: [TabItem]
    let matchingShelf: [TabItem]
    var matchingCount: Int { visible.count + matchingShelf.count }

    init(tabs: [TabItem], minimized: Set<UUID>, filter: CanvasFilter,
         state: (TabItem) -> CanvasSessionState, attention: ((TabItem) -> Bool)? = nil) {
        var visible: [TabItem] = []
        var shelf: [TabItem] = []
        var matchingShelf: [TabItem] = []
        for tab in tabs {
            let matches = filter == .needsYou ? (attention?(tab) ?? state(tab).needsAttention) : filter.includes(state(tab))
            if minimized.contains(tab.id) {
                shelf.append(tab)
                if matches { matchingShelf.append(tab) }
            } else if matches {
                visible.append(tab)
            }
        }
        self.visible = visible
        self.shelf = shelf
        self.matchingShelf = matchingShelf
    }
}
