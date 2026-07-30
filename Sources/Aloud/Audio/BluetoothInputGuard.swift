import CoreAudio
import Foundation

// Keeps the system default input off a Bluetooth headset that is doubling as
// the speakers, so no session ever has a reason to touch the headset's
// microphone — the thing that drops the whole headset into its mono
// phone-call profile.
//
// Continuous, not per-session, on purpose. Flipping the default input around
// a live capture was tried first and is exactly what produced the audible
// blip into call mode at the start of each dictation (and, when the flip
// raced the engine, a failed session that left the headset stuck there). The
// only way to *never hear that mode* is for the input to already be
// somewhere safe before any session begins: apply at launch, re-apply when
// devices or defaults change, and otherwise do nothing.
//
// The guard stands down when the user has explicitly picked a microphone in
// Settings — that choice is theirs, and the picker warns about Bluetooth.
// It also only ever acts on the exact situation MicrophonePolicy describes
// (Bluetooth headset as both input and output, built-in mic present);
// any other configuration is left entirely alone.
@MainActor
final class BluetoothInputGuard {
    var isActive: () -> Bool = { true }

    // Fires (main queue) after any audio-route change has settled — the same
    // signal the guard itself acts on. Lets the UI refresh anything derived
    // from the route (the Settings hint) without its own listener.
    var onRouteChange: (() -> Void)?

    private var installed = false
    private var pending: DispatchWorkItem?

    func start() {
        install()
        scheduleApply()
    }

    // Re-check now (used when the user's microphone choice changes).
    func reapply() { scheduleApply() }

    // Bluetooth connections settle in bursts of property changes; coalesce
    // them and act once, after the dust settles.
    private func scheduleApply() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.apply()
            self?.onRouteChange?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func apply() {
        guard isActive(),
              let uid = AudioDevices.preferredDefaultInputUID(),
              let id = AudioDevices.deviceID(forUID: uid),
              AudioDevices.defaultInputDeviceID() != id
        else { return }
        AudioDevices.setDefaultInputDevice(id)
    }

    private func install() {
        guard !installed else { return }
        installed = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scheduleApply() }
            }
        }
        for selector in [kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &address, DispatchQueue.main, block)
        }
    }
}
