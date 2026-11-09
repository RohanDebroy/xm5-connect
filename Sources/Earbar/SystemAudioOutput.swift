import CoreAudio
import Foundation

/// Reads macOS's current output. It does not change system routing or playback.
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
