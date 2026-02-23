import CoreAudio
import Foundation

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

final class DeviceManager {
    static let shared = DeviceManager()

    var onDevicesChanged: (() -> Void)?

    private var listenerRegistered = false

    private init() {
        registerDeviceChangeListener()
    }

    // MARK: - Device Enumeration

    func allOutputDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { id -> AudioDevice? in
            guard hasOutputStreams(id) else { return nil }
            guard let uid = deviceUID(id), let name = deviceName(id) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    func findDevice(named name: String) -> AudioDevice? {
        allOutputDevices().first { $0.name.contains(name) }
    }

    func fixedVolumeOutputDevices() -> [AudioDevice] {
        allOutputDevices().filter { device in
            !device.name.contains("BlackHole")
                && device.uid != AudioEngine.aggregateUID
                && !hasVolumeControl(device.id)
        }
    }

    func hasVolumeControl(_ deviceID: AudioDeviceID) -> Bool {
        for element: UInt32 in [0, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &address) {
                return true
            }
        }
        return false
    }

    // MARK: - Device Properties

    func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return getStringProperty(deviceID, address: &address)
    }

    func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return getStringProperty(deviceID, address: &address)
    }

    private func getStringProperty(_ deviceID: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> String? {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return nil
        }
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &result) == noErr,
              let cfStr = result?.takeUnretainedValue() else {
            return nil
        }
        return cfStr as String
    }

    // MARK: - Default Device

    func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }
        return deviceID
    }

    func setDefaultOutput(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id
        )
        return status == noErr
    }

    func defaultSystemOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }
        return deviceID
    }

    func setDefaultSystemOutput(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id
        )
        return status == noErr
    }

    // MARK: - Private

    private func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private func registerDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { [weak self] _, _ in
            self?.onDevicesChanged?()
        }
        listenerRegistered = true
    }
}
