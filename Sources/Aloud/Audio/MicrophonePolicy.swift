import Foundation

// Where the system default input should sit, and whether the noise filter
// may run at all — the judgement calls behind keeping headphone audio
// untouched.
//
// Opening a Bluetooth headset's microphone drags the whole headset out of
// its stereo music profile (A2DP) into the mono phone-call one (HFP) for as
// long as the mic is open. The built-in microphone hears no worse (HFP
// audio is 8–16 kHz), so when a headset is doubling as the speakers the
// input is parked on the built-in mic and the user's music stays untouched.
// An *explicitly* picked microphone is always honoured — the picker warns.
//
// Voice processing (the noise filter) echo-cancels against the *output
// device*: it inserts itself into that device's stream and processes it. On
// the Mac's own speakers that is the entire point — speaker sound bleeds
// into the microphone and needs cancelling. On any other output it is all
// cost: headphones don't bleed into the mic, and a Bluetooth headset gets
// its audio mangled for the whole session — tried, shipped to one user, and
// rolled back as a worse experience than not filtering. So the filter is
// simply unavailable off the built-in speakers, and the UI says so.
//
// Pure functions over plain values, so the rules are testable without
// Core Audio; AudioDevices gathers the live state and asks.
enum MicrophonePolicy {
    struct Device: Equatable {
        let uid: String
        let name: String
        let isBluetooth: Bool
    }

    // Core Audio gives the two halves of one Bluetooth headset distinct
    // UIDs that differ only by a direction suffix ("XX-…:input" /
    // "XX-…:output"). Strip it so the halves compare equal.
    static func baseUID(_ uid: String) -> String {
        for suffix in [":input", ":output"] where uid.hasSuffix(suffix) {
            return String(uid.dropLast(suffix.count))
        }
        return uid
    }

    static func sameHeadset(_ a: Device, _ b: Device) -> Bool {
        baseUID(a.uid) == baseUID(b.uid) || a.name == b.name
    }

    // Where the Mac's sound is going, as far as these rules care.
    enum Transport: Equatable { case builtIn, bluetooth, other }

    /// Whether the noise filter may engage right now: built-in output only.
    /// No output at all (nil) gets the benefit of the doubt — there is
    /// nothing playing to damage.
    static func voiceProcessingAllowed(outputTransport: Transport?) -> Bool {
        outputTransport == nil || outputTransport == .builtIn
    }

    /// nil = leave the default input alone; a UID = park it there instead.
    static func preferredUID(systemDefaultInput: Device?,
                             defaultOutput: Device?,
                             builtInUID: String?) -> String? {
        guard let input = systemDefaultInput, input.isBluetooth,
              let output = defaultOutput, output.isBluetooth,
              sameHeadset(input, output),
              let builtInUID
        else { return nil }
        return builtInUID
    }
}
