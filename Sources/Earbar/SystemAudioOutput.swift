import CoreAudio
import Foundation
import TandemCore

/// CoreAudio boundary for reading and explicitly changing the default media output.
enum SystemAudioOutput {
    static func current() -> AudioOutputIdentity? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return AudioOutputIdentity(uid: string(device: device, selector: kAudioDevicePropertyDeviceUID),
                                   name: string(device: device, selector: kAudioObjectPropertyName))
    }

    static func bluetoothOutputs() -> [AudioOutputEndpoint] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        guard size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return [] }
        return devices.compactMap { device in
            guard scalar(device, kAudioDevicePropertyDeviceIsAlive) == 1,
                  let transport = scalar(device, kAudioDevicePropertyTransportType),
                  [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport),
                  scalar(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioDevicePropertyScopeOutput) == 1 else { return nil }
            return AudioOutputEndpoint(id: device,
                uid: string(device: device, selector: kAudioDevicePropertyDeviceUID),
                name: string(device: device, selector: kAudioObjectPropertyName))
        }
    }

    @MainActor
    static func select(_ headphones: HeadphoneCandidate, isCurrent: () -> Bool) async throws {
        var target: AudioDeviceID?
        // A freshly activated Bluetooth media endpoint may take a moment to
        // appear. Re-enumerate within a bounded window; never guess another ID.
        for attempt in 0..<10 {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            target = AudioRoutingPolicy.outputID(for: headphones, outputs: bluetoothOutputs())
            if target != nil { break }
            if attempt < 9 { try await Task.sleep(nanoseconds: 150_000_000) }
        }
        guard var target else { throw TandemError.transport("The selected headphones are not available as a macOS audio output. Connect them in Bluetooth settings and retry.") }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        if currentID() == target { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &target)
        guard status == noErr else { throw TandemError.transport("macOS rejected the audio output change (\(status)).") }
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if currentID() == target { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TandemError.transport("macOS did not confirm the headphone output. Check Sound settings.")
    }

    private static func currentID() -> AudioDeviceID? {
        scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func scalar(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        // CoreAudio returns an owned CFString for UID/name properties. Use
        // unmanaged storage at the C boundary, then transfer ownership to ARC.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
