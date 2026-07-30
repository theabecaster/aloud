import CoreAudio
import Foundation

// Enumerate audio input devices via Core Audio so Settings can offer a mic picker.
struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    // Opening a Bluetooth mic drops the whole headset to its mono phone-call
    // profile — the picker warns about exactly this.
    let isBluetooth: Bool
}

enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name, isBluetooth: isBluetooth(id))
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    // Same lookup over every device, not just inputs — output devices (the
    // dimmer's restore target) never appear in the input list.
    static func deviceID(forOutputUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return nil }
        return ids.first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    // The stable identifier for a device the engine is already using. "Default
    // input" is a moving target — the answer to "which microphone is this"
    // has to come from the device itself.
    static func uid(forDeviceID id: AudioDeviceID) -> String? {
        guard id != 0 else { return nil }
        return stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    // Where the system default input *should* be right now, per
    // MicrophonePolicy: nil when the current default is fine, or the
    // built-in mic's UID when the default input is a Bluetooth headset that
    // is also the current output. Consumed by BluetoothInputGuard, which
    // applies it continuously so sessions never have to switch anything.
    static func preferredDefaultInputUID() -> String? {
        MicrophonePolicy.preferredUID(
            systemDefaultInput: defaultDevice(input: true),
            defaultOutput: defaultDevice(input: false),
            builtInUID: builtInInputUID())
    }

    // Whether the noise filter may engage right now — the answer depends on
    // where the Mac's sound is going, and MicrophonePolicy holds the rules.
    static func voiceProcessingAllowed() -> Bool {
        MicrophonePolicy.voiceProcessingAllowed(outputTransport: defaultOutputTransport())
    }

    private static func defaultOutputTransport() -> MicrophonePolicy.Transport? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        switch transportType(id) {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        default: return .other
        }
    }

    // The system default input device — the one thing that actually decides
    // where AVAudioEngine records from. The engine's input rides a
    // "default device aggregate" that snaps back to the system default
    // moments after start, so pointing the engine's own audio unit at a
    // device does not hold (measured: overridden ~0.5 s after engine.start).
    // Sessions that need a different microphone change the default itself,
    // and put it back after.
    static func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr else { return 0 }
        return id
    }

    @discardableResult
    static func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    // Whether the current output is a Bluetooth device — drives the Settings
    // footnote explaining why Aloud listens through the built-in microphone.
    static func defaultOutputIsBluetooth() -> Bool {
        defaultDevice(input: false)?.isBluetooth ?? false
    }

    // The current output device's display name, for "not available with %@"
    // hints. nil when there is no output at all.
    static func defaultOutputName() -> String? {
        defaultDevice(input: false)?.name
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let transport = transportType(id)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func defaultDevice(input: Bool) -> MicrophonePolicy.Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr,
              id != 0,
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName)
        else { return nil }
        return MicrophonePolicy.Device(uid: uid, name: name, isBluetooth: isBluetooth(id))
    }

    private static func builtInInputUID() -> String? {
        inputDevices().first {
            transportType($0.id) == kAudioDeviceTransportTypeBuiltIn
        }?.uid
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let listPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPtr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, listPtr) == noErr else { return 0 }
        let list = listPtr.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
