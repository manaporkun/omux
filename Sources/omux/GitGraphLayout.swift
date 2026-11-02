import Foundation

struct GitGraphRow: Identifiable, Equatable, Sendable {
    struct Track: Equatable, Sendable { let lane: Int; let color: Int }
    struct Edge: Equatable, Sendable { let from: Int; let to: Int; let color: Int }
    let commit: HistoryCommit
    let lane: Int
    let color: Int
    let incoming: [Track]
    let outgoing: [Edge]
    let width: Int
    var id: String { commit.id }
}

enum GitGraphLayout {
    private struct Lane { let target: String; let color: Int }

    /// Every open lane points at a not-yet-rendered ancestor. Collapse lanes only at a commit.
    static func rows(_ commits: [HistoryCommit]) -> [GitGraphRow] {
        var lanes: [Lane] = []
        var nextColor = 0
        return commits.map { commit in
            let incoming = lanes.enumerated().map { GitGraphRow.Track(lane: $0.offset, color: $0.element.color) }
            if !lanes.contains(where: { $0.target == commit.id }) {
                lanes.append(Lane(target: commit.id, color: nextColor)); nextColor += 1
            }
            let before = lanes
            let column = lanes.firstIndex(where: { $0.target == commit.id })!
            let color = lanes[column].color
            lanes.remove(at: column)
            for (index, parent) in commit.parents.enumerated() where !lanes.contains(where: { $0.target == parent }) {
                let parentColor = index == 0 ? color : nextColor
                if index > 0 { nextColor += 1 }
                lanes.insert(Lane(target: parent, color: parentColor), at: min(column + index, lanes.count))
            }
            var edges = before.enumerated().compactMap { index, lane -> GitGraphRow.Edge? in
                guard lane.target != commit.id, let to = lanes.firstIndex(where: { $0.target == lane.target }) else { return nil }
                return GitGraphRow.Edge(from: index, to: to, color: lane.color)
            }
            edges += commit.parents.compactMap { parent in
                guard let to = lanes.firstIndex(where: { $0.target == parent }) else { return nil }
                return GitGraphRow.Edge(from: column, to: to, color: lanes[to].color)
            }
            return GitGraphRow(commit: commit, lane: column, color: color, incoming: incoming, outgoing: edges,
                               width: max(before.count, lanes.count))
        }
    }
}
