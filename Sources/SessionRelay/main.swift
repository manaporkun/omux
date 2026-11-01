import Foundation

/// Keeps only bounded OSC program-status records, never terminal output or keystrokes.
struct StatusRelay {
    private var buffer = Data()
    private var records: [String: (state: String, packet: Data)] = [:]
    private var order: [String] = []
    private(set) var queries: [Data] = []
    var packets: [Data] { order.compactMap { records[$0]?.packet } }

    mutating func consume(_ chunk: Data) -> Bool {
        queries.removeAll(keepingCapacity: true)
        buffer.append(chunk)
        var changed = false
        let prefixes = [Data([27, 93])]
        while let start = prefixes.compactMap({ buffer.range(of: $0)?.lowerBound }).min() {
            if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 2)
            let bell = buffer[payloadStart...].firstIndex(of: 7)
            let st = buffer.range(of: Data([27, 92]), in: payloadStart..<buffer.endIndex)?.lowerBound
            guard let end = [bell, st].compactMap({ $0 }).min() else {
                if buffer.count > 8192 { buffer.removeFirst(2); continue }
                return changed
            }
            let length = buffer.distance(from: buffer.startIndex, to: end) + (buffer[end] == 7 ? 1 : 2)
            var packet = Data(buffer.prefix(length))
            buffer.removeFirst(length)
            // tmux passthrough doubles ESC. A record is still validated by SwiftTerm at display time.
            if let raw = String(data: packet, encoding: .utf8) {
                packet = Data(raw.replacingOccurrences(of: "\u{1b}\u{1b}", with: "\u{1b}").utf8)
            }
            guard packet.count <= 4096, let text = String(data: packet, encoding: .utf8) else { continue }
            let ending = packet.last == 7 ? 1 : 2
            let body = String(text.dropFirst(2).dropLast(ending))
            if body == "133;A" {
                let active = order.filter { ["working", "blocked"].contains(records[$0]?.state ?? "") }
                for id in active { records[id] = nil; order.removeAll { $0 == id }; changed = true }
                continue
            }
            if body == "7501;?" { queries.append(packet); continue }
            guard body.hasPrefix("7501;") else { continue }
            let pairs = body.dropFirst(5).split(separator: ":")
            var fields: [String: String] = [:]
            for pair in pairs {
                guard let equal = pair.firstIndex(of: "=") else { continue }
                fields[String(pair[..<equal])] = String(pair[pair.index(after: equal)...])
            }
            let id = fields["id"] ?? ""
            guard id.utf8.count <= 128,
                  id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-/.").contains($0) }) else { continue }
            if fields["state"] == "clear" {
                let removed = order.filter { id.isEmpty || $0 == id || $0.hasPrefix(id + "/") }
                for key in removed { records[key] = nil; order.removeAll { $0 == key } }
                changed = changed || !removed.isEmpty
            } else if let state = fields["state"], ["idle", "working", "done", "blocked", "error"].contains(state) {
                if records[id]?.packet != packet {
                    order.removeAll { $0 == id }
                    if records[id] == nil, order.count == 256 { records[order.removeFirst()] = nil }
                    order.append(id); records[id] = (state, packet); changed = true
                }
            }
        }
        // Keep one byte to recognize a split ESC ] prefix. Discard all ordinary terminal output.
        if buffer.count > 1 { buffer = Data(buffer.suffix(1)) }
        return changed
    }
}

if CommandLine.arguments.dropFirst().first == "--self-test" {
    var relay = StatusRelay()
    let working = Data("\u{1b}]7501;state=working:app=demo\u{7}".utf8)
    precondition(!relay.consume(Data("ordinary output\u{1b}".utf8)))
    precondition(relay.consume(Data(working.dropFirst())))
    precondition(relay.packets == [working])
    precondition(!relay.consume(working))
    let child = Data("\u{1b}]7501;state=blocked:id=child:kind=permission\u{1b}\\".utf8)
    precondition(!relay.consume(Data(child.prefix(12))))
    precondition(relay.consume(Data(child.dropFirst(12))))
    precondition(relay.packets.count == 2)
    precondition(relay.consume(Data("\u{1b}]133;A\u{7}".utf8)))
    precondition(relay.packets.isEmpty)
    _ = relay.consume(Data("\u{1b}]7501;state=done:id=child\u{7}".utf8))
    precondition(relay.consume(Data("\u{1b}]7501;state=clear\u{7}".utf8)))
    precondition(relay.packets.isEmpty)
    _ = relay.consume(Data(repeating: 65, count: 1_000_000))
    precondition(relay.consume(working))
    precondition(relay.packets == [working])
    let query = Data("\u{1b}]7501;?\u{7}".utf8)
    precondition(!relay.consume(query))
    precondition(relay.queries == [query] && relay.packets == [working])
    _ = relay.consume(Data("ordinary output".utf8))
    precondition(relay.queries.isEmpty)
    _ = relay.consume(Data("\u{1b}]7501;state=working:id=bad id\u{7}".utf8))
    precondition(relay.packets == [working])
    print("PASS: split frames, duplicate suppression, child records, shell prompt cleanup, clear, bounded buffering, ephemeral queries, malformed IDs")
    exit(0)
}

guard CommandLine.arguments.count == 2 else { exit(64) }
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
var relay = StatusRelay()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break }
    let changed = relay.consume(chunk)
    if let query = relay.queries.last {
        let url = destination.deletingLastPathComponent().appendingPathComponent("query.osc")
        try? query.write(to: url, options: .atomic)
    }
    if changed, let data = try? JSONEncoder().encode(relay.packets) {
        try? data.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
