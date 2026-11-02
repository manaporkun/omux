import SwiftUI

enum ProjectIcon: String, Codable, CaseIterable, Identifiable {
    case folder, terminal, code, globe, server, app, package, tools, book, design, game, sparkles

    var id: String { rawValue }
    var label: String {
        switch self {
        case .folder: return "Folder"
        case .terminal: return "Terminal"
        case .code: return "Code"
        case .globe: return "Web"
        case .server: return "Server"
        case .app: return "App"
        case .package: return "Package"
        case .tools: return "Tools"
        case .book: return "Docs"
        case .design: return "Design"
        case .game: return "Game"
        case .sparkles: return "Sparkles"
        }
    }
    var symbol: String {
        switch self {
        case .folder: return "folder"
        case .terminal: return "terminal"
        case .code: return "curlybraces"
        case .globe: return "globe"
        case .server: return "server.rack"
        case .app: return "app"
        case .package: return "shippingbox"
        case .tools: return "hammer"
        case .book: return "book.closed"
        case .design: return "paintpalette"
        case .game: return "gamecontroller"
        case .sparkles: return "sparkles"
        }
    }
}

struct ProjectIdentityIcon: View {
    let icon: ProjectIcon
    let color: TabColor

    init(group: TabGroup) { icon = group.icon; color = group.color }
    init(icon: ProjectIcon, color: TabColor) { self.icon = icon; self.color = color }

    var body: some View {
        Image(systemName: icon.symbol)
            .foregroundStyle(color.color ?? .secondary)
            .accessibilityLabel("\(icon.label) project icon, \(color == .none ? "default color" : color.rawValue)")
    }
}

/// Identity uses a colored symbol; the project name and session status keep their own styling.
struct ProjectIdentityPicker: View {
    @Binding var icon: ProjectIcon
    @Binding var color: TabColor
    let name: String
    private let palette: [TabColor] = [.none, .blue, .indigo, .purple, .pink, .teal, .green, .gray]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProjectIdentityIcon(icon: icon, color: color).font(.system(size: 18))
                Text(name.isEmpty ? "Project" : name).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Button("Reset appearance") { icon = .folder; color = .none }
                    .font(.caption).fixedSize()
                    .disabled(icon == .folder && color == .none)
            }
            Text("Project icon").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(ProjectIcon.allCases) { choice in
                    Button { icon = choice } label: {
                        ProjectIdentityIcon(icon: choice, color: color)
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background(icon == choice ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(icon == choice ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain).help(choice.label)
                    .accessibilityLabel(choice.label + " icon")
                    .accessibilityAddTraits(icon == choice ? [.isSelected] : [])
                }
            }
            Text("Project color").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                ForEach(palette) { choice in
                    Button { color = choice } label: {
                        ZStack {
                            Circle().fill(choice.color ?? Color.secondary.opacity(0.25))
                            if color == choice {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(choice == .none ? Color.primary : .white)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .padding(2)
                        .overlay(Circle().strokeBorder(color == choice ? Color.primary.opacity(0.65) : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(choice == .none ? "Default color" : choice.rawValue.capitalized)
                    .accessibilityLabel(choice == .none ? "Default project color" : choice.rawValue.capitalized + " project color")
                    .accessibilityAddTraits(color == choice ? [.isSelected] : [])
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
