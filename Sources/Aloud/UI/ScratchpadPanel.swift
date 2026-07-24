import AppKit
import SwiftUI

// The scratchpad's text, one plain-text file in the app state dir. Saved on
// every edit (the file is tiny; a lost thought is expensive) from a background
// queue, atomically — same shape as HistoryStore. Local only, like everything.
final class ScratchpadStore: ObservableObject {
    @Published var text: String {
        didSet { persist() }
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "aloud.scratchpad")

    init(fileURL: URL = AppPaths.scratchpadFile) {
        self.fileURL = fileURL
        text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    private func persist() {
        let snapshot = text
        let url = fileURL
        queue.async {
            AppPaths.ensureStateDir()
            try? snapshot.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// A small always-on-top note window toggled from the menu bar: somewhere to
// dictate a thought without hunting for a text field first. It's a capture
// surface, not a notes app — one text area, autosaved, frame remembered.
@MainActor
final class ScratchpadPanel {
    private var panel: NSPanel?
    private let store = ScratchpadStore()

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let panel = ensurePanel()
        // Activating on purpose: unlike the recording pill, the user dictates
        // *into* this window, so it must be able to take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.title = loc("Scratchpad")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Clear window + SwiftUI material = the system panel look without
        // drawing any chrome ourselves.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: ScratchpadView(store: store))
        panel.setFrameAutosaveName("AloudScratchpad")
        if panel.frame.origin == .zero { panel.center() }
        self.panel = panel
        return panel
    }
}

private struct ScratchpadView: View {
    @ObservedObject var store: ScratchpadStore

    var body: some View {
        TextEditor(text: $store.text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .background(.regularMaterial, ignoresSafeAreaEdges: .all)
    }
}
