import AppKit
import SwiftUI

struct CloneRepositorySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var remote = ""
    @State private var name = ""
    @State private var parent = FileManager.default.homeDirectoryForCurrentUser
    @State private var running = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clone Repository").font(.title2.bold())
            Text("Clone an HTTPS or SSH repository and open it as a project.")
                .foregroundStyle(.secondary)
            TextField("Repository URL", text: $remote)
                .onChange(of: remote) { old, new in
                    if name.isEmpty || name == RepositoryClone.repositoryName(old) {
                        name = RepositoryClone.repositoryName(new)
                    }
                }
            TextField("Folder name", text: $name)
            HStack {
                Text(parent.path).lineLimit(2).truncationMode(.middle)
                Spacer()
                Button("Choose Location…") { chooseLocation() }
            }
            Text("Private repositories use your existing Git credentials or SSH key. Configure access in Terminal before cloning.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Cloning repository…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                Button("Clone and Open") { clone() }.keyboardShortcut(.defaultAction)
                    .disabled(running || remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.isEmpty)
            }
        }
        .padding(24).frame(width: 490)
        .disabled(running)
        .interactiveDismissDisabled(running)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parent
        panel.prompt = "Choose"
        panel.message = "Choose the parent folder for the cloned repository."
        if panel.runModal() == .OK, let url = panel.url { parent = url }
    }

    private func clone() {
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try RepositoryClone.validate(remote: url, name: folder) }
        catch { self.error = error.localizedDescription; return }
        running = true
        error = nil
        let location = parent
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try RepositoryClone.clone(remote: url, parent: location, name: folder) }
            DispatchQueue.main.async {
                running = false
                switch result {
                case .success(let destination):
                    dismiss()
                    store.openFolder(destination.path)
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }
}
