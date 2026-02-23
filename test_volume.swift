import CoreAudio
import AudioToolbox
import Foundation

// Find the default output device
var deviceID = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var status = AudioObjectGetPropertyData(
    AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
)
print("Default output device ID: \(deviceID), status: \(status)")

// Get device name
var nameRef: CFString = "" as CFString
size = UInt32(MemoryLayout<CFString>.size)
address.mSelector = kAudioObjectPropertyName
status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &nameRef)
print("Device name: \(nameRef)")

// Check if device has volume control (hardware)
address = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyVolumeScalar,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
)
let hasHWVolume = AudioObjectHasProperty(deviceID, &address)
print("Has hardware volume (main): \(hasHWVolume)")

// Check master element
address.mElement = 0
let hasHWVolumeMaster = AudioObjectHasProperty(deviceID, &address)
print("Has hardware volume (element 0): \(hasHWVolumeMaster)")

// Check channel 1
address.mElement = 1
let hasHWVolumeC1 = AudioObjectHasProperty(deviceID, &address)
print("Has hardware volume (channel 1): \(hasHWVolumeC1)")

// Try VirtualMainVolume (AudioToolbox / AudioHardwareService)
var virtualVol: Float32 = 0
size = UInt32(MemoryLayout<Float32>.size)
address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
)
let hasVirtualVolume = AudioObjectHasProperty(deviceID, &address)
print("Has VirtualMainVolume: \(hasVirtualVolume)")

if hasVirtualVolume {
    status = AudioHardwareServiceGetPropertyData(deviceID, &address, 0, nil, &size, &virtualVol)
    print("Current VirtualMainVolume: \(virtualVol), status: \(status)")

    // Try setting it to 0.5
    var newVol: Float32 = 0.5
    status = AudioHardwareServiceSetPropertyData(deviceID, &address, 0, nil, size, &newVol)
    print("Set VirtualMainVolume to 0.5, status: \(status)")

    // Read back
    status = AudioHardwareServiceGetPropertyData(deviceID, &address, 0, nil, &size, &virtualVol)
    print("VirtualMainVolume after set: \(virtualVol), status: \(status)")
} else {
    print("VirtualMainVolume not available on this device")
}

// Check VirtualMainBalance
address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainBalance
let hasBalance = AudioObjectHasProperty(deviceID, &address)
print("Has VirtualMainBalance: \(hasBalance)")
