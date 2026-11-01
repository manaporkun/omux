import Foundation

/// UI state is independent of provider conversations and terminal processes.
struct CanvasWorkspace: Codable, Equatable {
    var projectID: UUID?
    var maximizedID: UUID?
    var projects: [UUID: ProjectCanvas] = [:]
    var pinnedProjects: Set<UUID> = []

    func project(_ id: UUID) -> ProjectCanvas { projects[id] ?? ProjectCanvas() }

    mutating func reconcile(groups: [TabGroup]) {
        let groupIDs = Set(groups.map(\.id))
        let tabIDs = Set(groups.flatMap { $0.tabs.map(\.id) })
        if let id = projectID, !groupIDs.contains(id) { projectID = groups.first?.id }
        if let id = maximizedID, !tabIDs.contains(id) { maximizedID = nil }
        pinnedProjects.formIntersection(groupIDs)
        projects = projects.filter { groupIDs.contains($0.key) }
        for group in groups where projects[group.id] != nil {
            projects[group.id]?.minimized.formIntersection(Set(group.tabs.map(\.id)))
        }
    }
}

struct ProjectCanvas: Codable, Equatable {
    var size: GridWindowSize = .medium
    var minimized: Set<UUID> = []
}

enum GridWindowSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String {
        switch self { case .small: return "S"; case .medium: return "M"; case .large: return "L" }
    }
    var minimum: CGSize {
        switch self {
        case .small: return CGSize(width: 220, height: 130)
        case .medium: return CGSize(width: 300, height: 170)
        case .large: return CGSize(width: 420, height: 230)
        }
    }
}

/// Chooses the largest readable landscape windows that fit; otherwise scrolls vertically.
struct TerminalGridLayout: Equatable {
    let columns: Int
    let width: CGFloat
    let height: CGFloat
    static let gap: CGFloat = 12

    init(count: Int, available: CGSize, size: GridWindowSize) {
        let count = max(1, count)
        let availableWidth = max(size.minimum.width, available.width)
        let availableHeight = max(0, available.height)
        let maxColumns = min(count, max(1, Int((availableWidth + Self.gap) / (size.minimum.width + Self.gap))))
        var best: (columns: Int, width: CGFloat, height: CGFloat, area: CGFloat)?
        for columns in 1...maxColumns {
            let width = (availableWidth - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)
            let rows = Int(ceil(Double(count) / Double(columns)))
            let minimumHeight = max(size.minimum.height, width / 2.8)
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
            height = ceil(max(size.minimum.height, width / 2.8))
        }
    }
}

enum CanvasSessionState: String, CaseIterable {
    case working, needsYou, idle, error, running, ended
    var label: String {
        switch self {
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .idle: return "Idle"
        case .error: return "Error"
        case .running: return "Running"
        case .ended: return "Ended"
        }
    }
    var needsAttention: Bool { self == .needsYou || self == .error }

    init(_ runtime: TabRuntime) {
        if runtime.exited { self = .ended }
        else if runtime.statusState == .error { self = .error }
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
