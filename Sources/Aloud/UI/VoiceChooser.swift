import AppKit
import SwiftUI

// How agents sound — used both in Settings and on the onboarding screen where
// the feature is switched on.
//
// Two controls, because there are two things worth deciding: which side the
// voice speaks from, and how fast. Aloud picks the best voice it has on the
// chosen side, so the user never meets a list of names they have no way to
// judge — "Samantha or Moira?" is a question about voices they have never
// heard, and the answer that matters to them is the one they can give without
// listening to six samples first.
//
// The shape is macOS's own. A two-way choice is a segmented control here and
// everywhere else on this platform; speech rate is a slider between a tortoise
// and a hare, an idiom that has meant "how fast it talks" on the Mac for
// twenty years. Nobody has to learn anything: they have set a voice on a Mac
// before.
//
// New strings here need entries in Sources/Aloud/Resources/*.lproj
// (en, es, de, fr, pt-BR) — shared files, added separately.
struct VoiceChooser: View {
    @ObservedObject var settings: SettingsStore
    /// `form` is a Settings pane's grouped rows; `card` is the bordered panel
    /// the onboarding screens are built from. Same controls, same order —
    /// only the chrome differs.
    enum Style { case form, card }
    var style: Style = .form

    @StateObject private var sample = VoiceSample()
    /// Shared with the agent bridge: who is loading what, and which voices are
    /// ready to speak. The play button waits on this rather than on its own
    /// idea of readiness, so warming once serves both.
    @ObservedObject private var voices = EnhancedVoices.shared
    /// Rebuilt on appear: a Mac with no male voice installed must not be
    /// offered one, and that can change while Aloud is running.
    @State private var genders: [VoiceGender] = VoiceCatalog.availableGenders

    var body: some View {
        Group {
            switch style {
            case .form: formBody
            case .card: cardBody
            }
        }
        .onAppear {
            // The one place the Mac is asked again: a voice added in System
            // Settings while Aloud was running counts from the next time the
            // picker appears, and nowhere in between does a redraw pay for it.
            VoiceCatalog.refresh()
            genders = VoiceCatalog.availableGenders
            sample.refreshReadiness(for: settings.agentVoiceGender)
            voices.warm(settings.agentVoiceGender)
        }
        .onChange(of: settings.agentVoiceSpeed) { _, speed in
            sample.speedChanged(to: speed, gender: settings.agentVoiceGender)
        }
        .onDisappear { sample.release() }
    }

    // MARK: - Settings

    private var formBody: some View {
        SwiftUI.Section {
            LabeledContent {
                HStack(spacing: 8) {
                    picker.frame(maxWidth: 180)
                    playButton
                }
            } label: {
                Text(loc("Voice gender"))
            }

            LabeledContent {
                speedSlider
            } label: {
                Text(loc("Speaking speed"))
            }
        } header: {
            Text(loc("Voice"))
        } footer: {
            Text(sample.standingIn
                 ? loc("Using a basic voice for now — Aloud’s own is still downloading.")
                 : loc("Agents ask their questions in this voice."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.default, value: sample.standingIn)
    }

    // MARK: - Onboarding

    // The same two controls in the panel style the rest of the screen uses, so
    // it reads as one more thing the screen tells you rather than a settings
    // pane that wandered in.
    private var cardBody: some View {
        VStack(spacing: 0) {
            cardRow(symbol: "waveform", title: loc("Voice")) {
                HStack(spacing: 8) {
                    picker.frame(maxWidth: 170)
                    playButton
                }
            }

            Divider().padding(.leading, 46)

            cardRow(symbol: "gauge.with.dots.needle.33percent", title: loc("Speed")) {
                speedSlider.frame(maxWidth: 190)
            }

        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func cardRow(symbol: String, title: String,
                         @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            Text(title)
                .font(.callout.weight(.semibold))
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Controls

    private var picker: some View {
        Picker("", selection: gender) {
            ForEach(genders) { gender in
                Text(gender.label).tag(gender)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityLabel(loc("Voice gender"))
    }

    // Hear it — the one control here whose answer cannot be read off the
    // screen.
    //
    // The first press after switching sides is not instant: that engine's
    // model has to load and compile before a single sample exists, which is
    // seconds on a cold voice. A play button that sits there looking pressable
    // through that reads as a broken button, so it becomes a spinner and stops
    // taking presses until there is something to hear.
    @ViewBuilder
    private var playButton: some View {
        if voices.warming.contains(settings.agentVoiceGender) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
                .accessibilityLabel(loc("Getting the voice ready"))
        } else {
            Button {
                sample.toggle(settings.agentVoiceGender, speed: settings.agentVoiceSpeed)
            } label: {
                Image(systemName: sample.isSpeaking ? "stop.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.text)
            .help(loc("Hear this voice"))
            .accessibilityLabel(sample.isSpeaking ? loc("Stop") : loc("Hear this voice"))
        }
    }

    // Tortoise to hare, the way every speech rate on this platform is set,
    // with the multiple spelled out because "somewhere left of centre" is not
    // something you can tell a colleague or set back later from memory.
    private var speedSlider: some View {
        HStack(spacing: 6) {
            Slider(value: $settings.agentVoiceSpeed,
                   in: VoiceSpeed.slowest...VoiceSpeed.fastest,
                   step: VoiceSpeed.step) {
                Text(loc("Speaking speed"))
            } minimumValueLabel: {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
            }
            .labelsHidden()
            .controlSize(.small)

            Text(VoiceSpeed.label(settings.agentVoiceSpeed))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Plumbing

    private var gender: Binding<VoiceGender> {
        Binding(get: { settings.agentVoiceGender },
                set: {
                    settings.agentVoiceGender = $0
                    sample.stop()
                    // Switching sides is the one moment we learn the user
                    // wants a voice that may not be here yet. Nothing is said
                    // about it beyond the footer — the fetch is Aloud's job.
                    EnhancedVoices.shared.ensure($0)
                    sample.refreshReadiness(for: $0)
                    // And the moment to pay this side's load, so the play
                    // button they reach for next is instant.
                    voices.warm($0)
                })
    }
}

// Playing the sample, and fetching Aloud's own voice when that is the upgrade
// on offer. Held apart from the view because both outlive a redraw: a sample is
// still speaking while the screen scrolls, and a download outlives the whole
// screen on the onboarding path.
@MainActor
final class VoiceSample: ObservableObject {
    @Published private(set) var isSpeaking = false
    /// True while a macOS voice is covering for one of Aloud's own that hasn't
    /// arrived yet — the app's "Basic" tier, said the same way dictation says
    /// it.
    @Published private(set) var standingIn = false

    // The speaker itself is shared (see SpeakerPool) — this only remembers
    // which one it last used, so a stop can reach it.
    private var speaker: Speaker?
    private var speaking: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    private var restart: Task<Void, Never>?
    /// Bumped by every start and every stop. A sample that finishes after the
    /// number moved on is stale and says nothing about what the button shows.
    private var run = 0

    // Short, and a question — this feature's whole job is asking one. A sample
    // that reads like marketing copy tells you less about how it will sound
    // when it actually matters.
    private static var sampleText: String {
        loc("This is me, thinking out loud. How’s the pace?")
    }

    func refreshReadiness(for gender: VoiceGender) {
        standingIn = VoiceCatalog.isStandingIn(gender)
        // A download that finishes while this screen is open should stop the
        // screen saying it hasn't. Nothing here drives the fetch — this only
        // watches for it landing, and stops the moment it has.
        guard standingIn else { watch?.cancel(); watch = nil; return }
        guard watch == nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if !VoiceCatalog.isStandingIn(gender) {
                    self.standingIn = false
                    self.watch = nil
                    // The better voice is here; the next sample resolves to
                    // it through the pool rather than reusing the stand-in.
                    self.speaker = nil
                    return
                }
            }
        }
    }

    func toggle(_ gender: VoiceGender, speed: Double) {
        guard !isSpeaking else { stop(); return }
        speak(gender, speed: speed)
    }

    /// The slider moved. The sample is how a user judges a pace, so a sample
    /// that keeps the old one while the slider says otherwise is showing them
    /// the wrong thing — it re-speaks at the new speed. Debounced, because a
    /// drag is dozens of changes and restarting on each would be a stutter
    /// rather than a preview.
    func speedChanged(to speed: Double, gender: VoiceGender) {
        speaker?.speed = speed
        guard isSpeaking else { return }
        restart?.cancel()
        restart = Task { [weak self] in
            // Long enough that a drag produces one restart at the end of it
            // rather than one per tick.
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.isSpeaking else { return }
            self.speak(gender, speed: speed)
        }
    }

    private func speak(_ gender: VoiceGender, speed: Double) {
        let voice = SpeakerPool.speaker(for: VoiceCatalog.resolved(gender: gender),
                                        speed: speed)
        speaker = voice
        // Deliberately no `stop()` here. Replacing what is playing is the audio
        // layer's job — it schedules the new utterance over the old one, a
        // single swap — and stopping first only races it: the stop unwinds
        // behind the buffer that was just queued and flushes part of it, so the
        // sample says half its sentence and quits. What a stop was doing here
        // was keeping stale state out, and a run number does that without
        // touching the audio at all.
        //
        // One state change, not two: the button goes to Stop and stays there
        // until the sample ends. It used to wait for audio to actually start
        // and flick through a spinner on the way, which on a warm voice is a
        // fifth of a second of stutter — worse than the honest half-beat of
        // silence it was trying to explain. Waiting on a *cold* voice is what
        // `warm` exists to prevent.
        run += 1
        let mine = run
        isSpeaking = true
        speaking = Task { [weak self] in
            do {
                try await voice.speak(Self.sampleText)
            } catch {
                // A sample that fails silently is indistinguishable from a
                // dead button, and this is the one control whose whole job is
                // making a sound. Say so where a developer will find it.
                FileHandle.standardError.write(Data(
                    "voice preview failed: \(error.localizedDescription)\n".utf8))
            }
            // Only the newest sample owns the button: an older one finishing
            // because it was interrupted must not report silence over a sample
            // that is still speaking.
            guard let self, self.run == mine else { return }
            self.isSpeaking = false
        }
    }

    func stop() {
        run += 1
        restart?.cancel()
        restart = nil
        speaking?.cancel()
        speaking = nil
        speaker?.stop()
        isSpeaking = false
    }

    // Off screen, let the voice go: an idle audio engine keeps the output
    // device awake, and on a Bluetooth headset that can pin it into call mode.
    // Dropping the reference is what closes it.
    // Off screen: stop talking, stop watching. The speaker itself stays in
    // the pool — it is shared with the agent bridge, and dropping it here
    // would make the next question pay the load this pane just paid.
    func release() {
        stop()
        watch?.cancel()
        watch = nil
        speaker = nil
    }

}
