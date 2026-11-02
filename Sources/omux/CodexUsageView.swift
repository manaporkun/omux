import SwiftUI

struct CodexUsageView: View {
    @ObservedObject private var codex = CodexManager.shared
    @ViewState private var showingDetails = false
    @AppStorage(Prefs.usageInterval) private var usageInterval = 300.0

    var body: some View {
        Button { showingDetails.toggle() } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Codex limits")
                    Spacer()
                    if let limit = codex.limits.max(by: { $0.percent < $1.percent }) {
                        Text("\(limit.label) \(limit.percent)% used").foregroundStyle(limit.tint)
                    } else { Text("Details").foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }

            }
            .font(.system(size: 10)).monospacedDigit().contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 15).padding(.top, 10)
        .help("Codex subscription usage and reset times")
        .popover(isPresented: $showingDetails, arrowEdge: .trailing) {
            details.padding(16).frame(width: 320)
        }
        .task(id: usageInterval) {
            while !Task.isCancelled {
                await codex.refreshUsage()
                do { try await Task.sleep(for: .seconds(max(30, usageInterval))) }
                catch { return }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex subscription").font(.headline)
                Spacer()
                Button { Task { await codex.refreshUsage() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh account limits")
            }
            if let plan = codex.plan { Text(plan.replacingOccurrences(of: "_", with: " ").capitalized) }
            if let error = codex.usageError { Text(error).foregroundStyle(.secondary) }
            ForEach(codex.limits) { limit in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(limit.label) · \(limit.percent)% used\(limit.percent >= 100 ? " · Limit reached" : "")")
                    ProgressView(value: Double(min(100, limit.percent)), total: 100).tint(limit.tint)
                    if let reset = limit.resetsAt {
                        Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                    }
                }
            }
            if let updated = codex.usageUpdatedAt {
                Text("Account limits updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
                if Date().timeIntervalSince(updated) > max(60, usageInterval * 2) {
                    Text("Account data is stale. Refresh to check current limits.").foregroundStyle(.orange)
                }
            }

        }
        .font(.caption)
    }
}

/// Context belongs to one conversation and is shown on its active terminal card.
struct SessionContextBar: View {
    @EnvironmentObject private var store: Store
    @ViewState private var terminalContext: CodexTerminalContext?
    @ViewState private var claudeUsage: CodexContextUsage?
    @ObservedObject private var codex = CodexManager.shared
    let tabID: UUID
    let provider: SessionProvider

    private var usage: CodexContextUsage? {
        codex.contextUsage(for: tabID) ?? terminalContext?.usage ?? (terminalContext == nil ? claudeUsage : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let usage {
                HStack {
                    Text("Context")
                    Spacer(minLength: 4)
                    if let window = usage.window, let fraction = usage.fraction {
                        Text("\(Int(fraction * 100))% used · \(usage.tokens.formatted()) / \(window.formatted()) tokens")
                    } else {
                        Text("\(usage.tokens.formatted()) tokens · Window size unavailable")
                    }
                }
                if let fraction = usage.fraction {
                    ProgressView(value: fraction).tint(fraction >= 0.9 ? .orange : .accentColor)
                }
            } else if let context = terminalContext {
                HStack {
                    Text("Context window")
                    Spacer(minLength: 4)
                    if let remaining = context.remainingPercent {
                        Text("\(remaining)% left")
                    } else if let capacity = context.modelCapacity {
                        Text("Model capacity · \(capacity.formatted()) tokens")
                    }
                }
                if let remaining = context.remainingPercent {
                    ProgressView(value: Double(100 - remaining), total: 100)
                } else {
                    Text("Conversation usage unavailable").foregroundStyle(.tertiary)
                }
            } else {
                HStack {
                    Text("Context window")
                    Spacer(minLength: 4)
                    Text(provider == .claude ? "Waiting for Claude update" : provider == .codex ? "Waiting for Codex update" : "Not reported by this session")
                }
            }
        }
        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .task(id: "\(tabID)-\(provider.rawValue)") {
            let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
            while !Task.isCancelled {
                if let probe = store.terminalContextProbe(tabID) {
                    let context = await Task.detached {
                        CodexTerminalContext.inspect(root: probe.pid, lines: probe.lines, home: home)
                    }.value
                    guard !Task.isCancelled else { return }
                    terminalContext = context
                } else { terminalContext = nil }
                if terminalContext == nil, provider == .claude, let session = store.tab(tabID)?.claudeSessionID {
                    let projects = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude").appendingPathComponent("projects")
                    let context = await Task.detached { () -> CodexContextUsage? in
                        let transcript = ClaudeContextUsage.inspect(sessionID: session, projects: projects)
                        let reported = ClaudeContextUsage.reportedUsage(sessionID: session)
                        // Prefer a newer request over an old status-line snapshot.
                        if let transcript, let reported, transcript.updatedAt > reported.updatedAt { return transcript }
                        return reported ?? transcript
                    }.value
                    guard !Task.isCancelled else { return }
                    claudeUsage = context
                } else { claudeUsage = nil }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .help(usage.map {
            "Last reported \($0.updatedAt.formatted(date: .omitted, time: .shortened)). Context may drop after compaction. Separate from subscription quota."
        } ?? (terminalContext?.modelCapacity != nil ? "Model capacity comes from Codex’s local model catalog. Session overrides and compaction thresholds can differ. Usage comes from this terminal’s Codex process when reported." : provider == .claude ? "Claude reports request tokens in this conversation’s transcript, including cache reads and cache writes. Window size is unavailable unless reported by Claude." : provider == .codex ? "Codex reports context usage as the conversation runs." : "No Codex context is visible yet. Start Codex or select a terminal running it."))
    }
}
