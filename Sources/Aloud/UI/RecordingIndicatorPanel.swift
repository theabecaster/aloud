import AppKit
import SwiftUI

// The small floating "I'm listening" pill: a non-activating panel near the
// bottom-center of the active screen, visible on all Spaces, never steals focus.
// Shows a live level meter while recording, a spinner while transcribing, and
// short hint messages. Subtle fade/scale in and out.
@MainActor
final class RecordingIndicatorPanel {
    private var panel: NSPanel?
    private let model = IndicatorModel()
    private var levelTimer: Timer?
    // Bumped by present() and hide() so a hide's fade-out completion can tell
    // whether a show snuck in behind it (hands-free is a cancel immediately
    // followed by a re-show) and must not order the panel out.
    private var hideGeneration = 0

    func show(levelProvider: @escaping () -> Float) {
        model.mode = .recording
        model.hint = nil
        model.isLocked = false
        present()
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak model] _ in
            let level = levelProvider()
            Task { @MainActor in model?.level = level }
        }
    }

    // Hands-free lock engaged: keep the live meter, add the lock affordance.
    func showLocked() {
        model.isLocked = true
    }

    func showTranscribing() {
        levelTimer?.invalidate()
        model.mode = .transcribing
        present()
    }

    func showHint(_ text: String) {
        levelTimer?.invalidate()
        model.mode = .hint
        model.hint = text
        present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.model.mode == .hint { self?.hide() }
        }
    }

    func hide() {
        levelTimer?.invalidate()
        levelTimer = nil
        guard let panel else { return }
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideGeneration == generation else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func present() {
        hideGeneration += 1   // invalidate any in-flight hide completion
        let panel = ensurePanel()
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: IndicatorView(model: model))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return }
        panel.setContentSize(NSSize(width: 220, height: 44))
        let f = screen.visibleFrame
        let x = f.midX - panel.frame.width / 2
        let y = f.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class IndicatorModel: ObservableObject {
    enum Mode { case recording, transcribing, hint }
    @Published var mode: Mode = .recording
    @Published var level: Float = 0
    @Published var hint: String?
    @Published var isLocked = false
}

struct IndicatorView: View {
    @ObservedObject var model: IndicatorModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .recording:
                // Hands-free trades the red mic for an orange one plus a lock —
                // a quiet "still listening" that users can discover on their own.
                Image(systemName: "mic.fill")
                    .foregroundStyle(model.isLocked ? Color.orange : Color.red)
                LevelMeter(level: model.level)
                    .frame(width: 90, height: 18)
                if model.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.orange)
                }
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                Text("Typing…")
                    .foregroundStyle(.secondary)
            case .hint:
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(model.hint ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.25), value: model.mode == .recording)
        .animation(.spring(duration: 0.25), value: model.isLocked)
    }
}

// A row of bars that follow the live input level — system-toned, no custom drawing
// beyond simple rounded rectangles.
struct LevelMeter: View {
    var level: Float
    private let barCount = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barActive(i) ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 3)
                    .frame(height: barHeight(i))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func barActive(_ i: Int) -> Bool {
        Float(i) / Float(barCount) < level
    }

    private func barHeight(_ i: Int) -> CGFloat {
        // Gentle center-weighted profile so the meter reads as a waveform.
        let x = Double(i) / Double(barCount - 1)
        let profile = 0.4 + 0.6 * sin(x * .pi)
        return CGFloat(8 + 10 * profile)
    }
}
