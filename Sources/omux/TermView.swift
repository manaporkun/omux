import AppKit
import SwiftTerm
import SwiftUI

enum TermEvent {
    case bell
    case title(String)
    case directory(String?)
    case exited
    /// OSC 7501: the root record's state, kind and message, plus every other record.
    case status(TabRuntime.StatusState?, kind: String?, message: String?, children: [TabRuntime.StatusChild])
    /// ⌘-click on a file path in the output.
    case openPath(String)
    /// A desktop notification the program asked for (OSC 9 or OSC 777).
    case notification(title: String?, body: String)
}

/// Receives process callbacks on behalf of a TermView. Kept separate because
/// LocalProcessTerminalView already declares methods with these signatures.
private final class ProcessEvents: LocalProcessTerminalViewDelegate {
    weak var owner: TermView?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        owner?.emit(.title(title))
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 sends a file:// URL
        let path = directory.flatMap { URL(string: $0)?.path ?? $0 }
        owner?.emit(.directory(path))
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        owner?.emit(.exited)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        owner?.emit(.exited)
    }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        let children = records.filter { !$0.id.isEmpty }.map {
            TabRuntime.StatusChild(id: $0.id, state: TabRuntime.StatusState(rawValue: $0.state.rawValue),
                                   kind: $0.kind?.rawValue, message: $0.message, title: $0.title)
        }
        guard let root = records.first(where: { $0.id.isEmpty }) ?? records.last else {
            owner?.emit(.status(nil, kind: nil, message: nil, children: []))
            return
        }
        let state = TabRuntime.StatusState(rawValue: root.state.rawValue)
        owner?.emit(.status(state, kind: root.kind?.rawValue, message: root.message, children: children))
    }
}

final class TermView: LocalProcessTerminalView {
    let tabID: UUID
    var onEvent: ((TermEvent) -> Void)?
    var onFocus: (() -> Void)?
    private let events = ProcessEvents()
    private var oscObservation: TerminalOscObservation?

    init(tabID: UUID) {
        self.tabID = tabID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500),
                   font: Fonts.terminal(),
                   options: TerminalOptions(scrollback: 5000))
        events.owner = self
        processDelegate = events
        // Option composes the layout's character (⌥Q is "@" on a Turkish layout) and
        // stays Meta only on keys with no character: arrows, ⌥⏎, ⌥⌫, Escape, Tab.
        optionAsMetaKey = false
        optionAsMetaKeyForFunctionalKeys = true
        apply(Theme.current)
        registerForDraggedTypes([.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        // Observed, not handled, so SwiftTerm keeps drawing OSC 9;4 progress itself.
        oscObservation = observeOscEvents { [weak self] event in
            guard let note = Self.notification(code: event.code, payload: event.payload) else { return }
            Task { @MainActor in self?.emit(.notification(title: note.title, body: note.body)) }
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    func apply(_ theme: Theme) {
        font = Fonts.terminal()
        nativeBackgroundColor = theme.background
        nativeForegroundColor = theme.foreground
        caretColor = theme.foreground
        installColors(theme.palette)
    }

    fileprivate func emit(_ event: TermEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { self.onEvent?(event) }
        }
    }

    /// ⌘-click: file paths go to the preview panel, folders (app bundles too) are shown in
    /// Finder rather than opened, everything else (URLs) goes to the system.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let path = Self.filePath(from: link) {
            emit(.openPath(path))
        } else if let folder = Self.filePath(from: link, folders: true) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
        } else {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }

    nonisolated static func filePath(from link: String, folders: Bool = false) -> String? {
        var raw = link.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("file://"), let url = URL(string: raw) { raw = url.path }
        guard raw.hasPrefix("/") || raw.hasPrefix("~") else { return nil }
        // Drop trailing punctuation Claude's prose leaves on paths.
        while let last = raw.last, ".,:;)]}'\"".contains(last) { raw.removeLast() }
        var path = (raw as NSString).expandingTildeInPath
        // "Foo.swift:12" and "Foo.swift:12:4", as compilers and agents print locations.
        if !FileManager.default.fileExists(atPath: path),
           let location = path.range(of: #":[0-9]+(:[0-9]+)?\z"#, options: .regularExpression) {
            path = String(path[..<location.lowerBound])
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue == folders else { return nil }
        return path
    }

    // MARK: Images and files

    /// ⌘V with files or an image on the clipboard pastes their paths, which Claude Code and
    /// Codex read as attachments. Text pastes as before; an image only wins when there is no text.
    override func paste(_ sender: Any) {
        let board = NSPasteboard.general
        do {
            if let text = try Self.attachmentText(from: board) {
                paste(text)
            } else {
                super.paste(sender)
            }
        } catch {
            NSSound.beep()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let board = sender.draggingPasteboard
        let readable = board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || board.canReadObject(forClasses: [NSImage.self, NSFilePromiseReceiver.self], options: nil)
        return readable && sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        do {
            // Photos and browsers hand over a promise of the file, not the file itself.
            if !board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
               let promises = board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
                window?.makeFirstResponder(self)
                try receive(promises)
                return true
            }
            guard let text = try Self.attachmentText(from: board, preferText: false) else { return false }
            window?.makeFirstResponder(self)
            paste(text)
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    /// Pastes each promised file's path as it arrives, in a folder of its own so names can't collide.
    private func receive(_ promises: [NSFilePromiseReceiver]) throws {
        let dir = Self.attachmentDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for promise in promises {
            promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { [weak self] url, error in
                if error == nil {
                    self?.paste(Self.shellEscaped([url]) + " ")
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    /// Preserve ordinary text pastes; file URLs and image-only clipboard contents become paths.
    static func attachmentText(from board: NSPasteboard, preferText: Bool = true,
                               directory: URL? = nil) throws -> String? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return shellEscaped(urls) + " "
        }
        if preferText, board.string(forType: .string) != nil { return nil }
        guard let image = NSImage(pasteboard: board) else { return nil }
        return shellEscaped([try save(image, directory: directory)]) + " "
    }

    /// Paths the way a shell, Claude Code and Codex read them: spaces and specials escaped.
    /// Control characters become $'\xNN', so a newline in a name can't end the command.
    nonisolated static func shellEscaped(_ urls: [URL]) -> String {
        urls.map { url in
            url.path.unicodeScalars.map { ch in
                if ch.value < 0x20 || ch.value == 0x7f { return String(format: "$'\\x%02x'", ch.value) }
                return " '\"()[]{}&;|<>$`\\*?#~!".unicodeScalars.contains(ch) ? "\\\(ch)" : String(ch)
            }.joined()
        }.joined(separator: " ")
    }

    private static var attachmentDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omux-paste", isDirectory: true)
    }

    /// Saves a pasted image as PNG under the temporary folder, like the browser's picks.
    private static func save(_ image: NSImage, directory: URL?) throws -> URL {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let dir = directory ?? attachmentDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("image-\(UUID().uuidString).png")
        try png.write(to: url, options: .atomic)
        return url
    }

    /// Types text into the session as a paste, so newlines don't submit it early.
    func paste(_ text: String) {
        if terminalInputStateSnapshot()?.bracketedPasteMode == true {
            send(txt: Self.bracketedPaste(text))
        } else {
            send(txt: text)
        }
    }

    /// Without ESC, text from a file name or a log can't end the paste with its own
    /// ESC[201~ and have the lines after it typed and submitted.
    nonisolated static func bracketedPaste(_ text: String) -> String {
        "\u{1b}[200~" + text.replacingOccurrences(of: "\u{1b}", with: "") + "\u{1b}[201~"
    }

    /// The main buffer's text, scrollback included. Read it here on the main actor;
    /// the parsers below are safe to run on the copy from any thread.
    func scrollbackText() -> String {
        String(data: getBufferAsData(kind: .normal), encoding: .utf8) ?? ""
    }

    /// A desktop notification in an OSC payload: `OSC 9 ; body` (iTerm2) or
    /// `OSC 777 ; notify ; title ; body` (Ghostty, rxvt). Claude Code sends these when its
    /// notification channel is `iterm2` or `ghostty`, for itself and for its plugins.
    nonisolated static func notification(code: Int, payload: [UInt8]) -> (title: String?, body: String)? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        switch code {
        case 9:
            // A number first is a ConEmu command, like 9;4 progress, not a message.
            guard !text.isEmpty, text.range(of: #"^\d+(;|$)"#, options: .regularExpression) == nil else { return nil }
            return (nil, text)
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "notify", !parts[2].isEmpty else { return nil }
            return (parts[1].isEmpty ? nil : String(parts[1]), String(parts[2]))
        default:
            return nil
        }
    }

    /// Local server URLs (localhost, 127.0.0.1, …) in `text`, oldest first.
    nonisolated static func mentionedLocalURLs(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(?:/[^\s'"<>)\]]*)?"#)
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            var url = String(text[range])
            while let last = url.last, ".,:;".contains(last) { url.removeLast() }
            result.removeAll { $0 == url }
            result.append(url)
        }
        return result
    }

    /// File paths that appear in `text` and still exist, oldest first.
    nonisolated static func mentionedPaths(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?<![\w])(?:~|/)[\w.+@%~/-]+"#)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let path = Self.filePath(from: String(text[range])) else { continue }
            if seen.insert(path).inserted { result.append(path) } else if let i = result.firstIndex(of: path) {
                result.remove(at: i); result.append(path)
            }
        }
        return result
    }

    override nonisolated func bell(source: Terminal) {
        super.bell(source: source)
        DispatchQueue.main.async {
            NSSound.beep()
            self.onEvent?(.bell)
        }
    }
}

/// Hosts the long-lived TermView for the selected tab. Terminal views are owned by
/// the Store so switching tabs reparents a view instead of recreating the session.
struct TerminalHost: NSViewRepresentable {
    let termView: TermView
    let theme: Theme
    var isFocused = true

    final class Coordinator { var currentID: UUID?; var wasFocused = false }

    final class Container: NSView {
        weak var terminal: TermView?
        var focusRequested = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusIfReady()
        }

        func focusIfReady() {
            guard focusRequested, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusRequested, let terminal = self.terminal,
                      terminal.superview === self, let window = self.window, window.attachedSheet == nil else { return }
                if window.makeFirstResponder(terminal) { self.focusRequested = false }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        container.terminal = termView
        container.layer?.backgroundColor = theme.background.cgColor
        let changed = context.coordinator.currentID != termView.tabID || termView.superview !== container
        if changed {
            context.coordinator.currentID = termView.tabID
            container.subviews.forEach { $0.removeFromSuperview() }
            termView.frame = container.bounds
            termView.autoresizingMask = [.width, .height]
            container.addSubview(termView)
        }
        if !isFocused { container.focusRequested = false }
        else if changed || !context.coordinator.wasFocused { container.focusRequested = true }
        container.focusIfReady()
        context.coordinator.wasFocused = isFocused
    }
}
