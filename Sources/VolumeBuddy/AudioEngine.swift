import AudioToolbox
import CoreAudio
import Foundation
import os

private let engineLog = Logger(subsystem: "com.local.VolumeBuddy", category: "AudioEngine")

final class AudioEngine {
    fileprivate var audioUnit: AudioUnit?

    private var aggregateDeviceID: AudioDeviceID = 0

    var isRunning: Bool {
        guard let au = audioUnit else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(au, kAudioOutputUnitProperty_IsRunning,
                             kAudioUnitScope_Global, 0, &running, &size)
        return running != 0
    }

    // MARK: - Lifecycle

    func start(blackHoleID: AudioDeviceID, blackHoleUID: String,
               outputID: AudioDeviceID, outputUID: String) throws {

        // Match sample rates — BlackHole defaults to 48kHz, output may differ
        let targetRate = sampleRate(deviceID: blackHoleID)
        if sampleRate(deviceID: outputID) != targetRate {
            setSampleRate(deviceID: outputID, rate: targetRate)
            Thread.sleep(forTimeInterval: 0.3) // let CoreAudio settle
            engineLog.info("Set output sample rate to \(targetRate) Hz")
        }

        // Create aggregate: BlackHole (input) + output device
        let aggID = try createAggregateDevice(inputUID: blackHoleUID, outputUID: outputUID)
        aggregateDeviceID = aggID

        // Create HAL I/O unit
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw EngineError.componentNotFound
        }

        var au: AudioUnit?
        var status = AudioComponentInstanceNew(component, &au)
        guard status == noErr, let au else {
            throw EngineError.cannotCreateUnit(status)
        }
        audioUnit = au

        // Enable input on bus 1
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1,
                                      &enableInput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw EngineError.cannotEnableIO(status) }

        // Set aggregate as the device (single device for both I/O)
        var deviceID = aggID
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0,
                                      &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw EngineError.cannotSetDevice(status) }

        // Output channel map: one entry per aggregate output channel.
        // Aggregate output = [BlackHole out (16ch)] + [output out (2ch)] = 18 channels.
        // Map: silence BlackHole channels, route AU stereo to output channels.
        let bhOutCh = outputChannelCount(deviceID: blackHoleID)
        let outDevCh = outputChannelCount(deviceID: outputID)
        let totalOutCh = bhOutCh + outDevCh
        var outputMap = [Int32](repeating: -1, count: totalOutCh)
        outputMap[bhOutCh] = 0      // AU left  → output left
        outputMap[bhOutCh + 1] = 1  // AU right → output right
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_ChannelMap,
                                      kAudioUnitScope_Output, 0,
                                      &outputMap, UInt32(outputMap.count * MemoryLayout<Int32>.size))
        guard status == noErr else { throw EngineError.cannotSetFormat(status) }
        engineLog.debug("Output channel map: \(totalOutCh) channels, output at [\(bhOutCh),\(bhOutCh+1)]")

        // Input channel map: one entry per aggregate input channel (16 from BlackHole).
        // Route device ch0 → AU ch0, device ch1 → AU ch1, ignore the rest.
        let totalInCh = inputChannelCount(deviceID: aggID)
        var inputMap = [Int32](repeating: -1, count: totalInCh)
        inputMap[0] = 0  // BlackHole in ch0 → AU ch0
        inputMap[1] = 1  // BlackHole in ch1 → AU ch1
        status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_ChannelMap,
                                      kAudioUnitScope_Input, 1,
                                      &inputMap, UInt32(inputMap.count * MemoryLayout<Int32>.size))
        guard status == noErr else { throw EngineError.cannotSetFormat(status) }
        engineLog.debug("Input channel map: \(totalInCh) channels, reading [0,1]")

        // Use stereo float32 at the matched sample rate
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: targetRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        // Set format on output scope of input bus (what we read from BlackHole)
        status = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1,
                                      &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw EngineError.cannotSetFormat(status) }

        // Set format on input scope of output bus (what we send to output device)
        status = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0,
                                      &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw EngineError.cannotSetFormat(status) }

        // Render callback on output bus
        var callbackStruct = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0,
                                      &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw EngineError.cannotSetCallback(status) }

        status = AudioUnitInitialize(au)
        guard status == noErr else { throw EngineError.cannotInitialize(status) }

        status = AudioOutputUnitStart(au)
        guard status == noErr else { throw EngineError.cannotStart(status) }

        engineLog.info("Started — output at channel offset \(bhOutCh)")
    }

    func stop() {
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
    }

    func restart(blackHoleID: AudioDeviceID, blackHoleUID: String,
                 outputID: AudioDeviceID, outputUID: String) throws {
        stop()
        try start(blackHoleID: blackHoleID, blackHoleUID: blackHoleUID,
                  outputID: outputID, outputUID: outputUID)
    }

    // MARK: - Aggregate Device

    static let aggregateUID = "com.local.VolumeBuddy.Aggregate"

    func destroyStaleAggregate() {
        // Clean up any non-private aggregate left by a previous crash
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return }

        for id in deviceIDs {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &uidAddr, 0, nil, &uidSize) == noErr else { continue }
            var uid: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
                  let cfStr = uid?.takeUnretainedValue() else { continue }
            if (cfStr as String) == Self.aggregateUID {
                engineLog.warning("Destroying stale aggregate device \(id)")
                AudioHardwareDestroyAggregateDevice(id)
                return
            }
        }
    }

    private func createAggregateDevice(inputUID: String, outputUID: String) throws -> AudioDeviceID {
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: Self.aggregateUID,
            kAudioAggregateDeviceNameKey as String: "VolumeBuddy Aggregate",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [
                    kAudioSubDeviceUIDKey as String: inputUID,
                    kAudioSubDeviceDriftCompensationKey as String: true,
                ],
                [kAudioSubDeviceUIDKey as String: outputUID],
            ],
            kAudioAggregateDeviceMasterSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceClockDeviceKey as String: outputUID,
        ]

        var aggregateID: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw EngineError.cannotCreateAggregate(status)
        }
        return aggregateID
    }

    // MARK: - Helpers

    private func inputChannelCount(deviceID: AudioDeviceID) -> Int {
        return channelCount(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
    }

    private func outputChannelCount(deviceID: AudioDeviceID) -> Int {
        return channelCount(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
    }

    private func channelCount(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(size))
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buf) == noErr else { return 0 }

        let abl = buf.withMemoryRebound(to: AudioBufferList.self, capacity: 1) {
            UnsafeMutableAudioBufferListPointer($0)
        }
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Sample Rate

    private func sampleRate(deviceID: AudioDeviceID) -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return rate
    }

    private func setSampleRate(deviceID: AudioDeviceID, rate: Float64) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var r = rate
        AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                   UInt32(MemoryLayout<Float64>.size), &r)
    }

    // MARK: - Errors

    enum EngineError: LocalizedError {
        case componentNotFound
        case cannotCreateUnit(OSStatus)
        case cannotCreateAggregate(OSStatus)
        case cannotEnableIO(OSStatus)
        case cannotSetDevice(OSStatus)
        case cannotSetFormat(OSStatus)
        case cannotSetCallback(OSStatus)
        case cannotInitialize(OSStatus)
        case cannotStart(OSStatus)

        var errorDescription: String? {
            switch self {
            case .componentNotFound: return "HAL Output audio component not found"
            case .cannotCreateUnit(let s): return "Failed to create audio unit (OSStatus \(s))"
            case .cannotCreateAggregate(let s): return "Failed to create aggregate device (OSStatus \(s))"
            case .cannotEnableIO(let s): return "Failed to enable I/O (OSStatus \(s))"
            case .cannotSetDevice(let s): return "Failed to set audio device (OSStatus \(s))"
            case .cannotSetFormat(let s): return "Failed to set stream format (OSStatus \(s))"
            case .cannotSetCallback(let s): return "Failed to set render callback (OSStatus \(s))"
            case .cannotInitialize(let s): return "Failed to initialize audio unit (OSStatus \(s))"
            case .cannotStart(let s): return "Failed to start audio unit (OSStatus \(s))"
            }
        }
    }
}

// Render callback — runs on the real-time audio thread
private func renderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    return AudioUnitRender(engine.audioUnit!, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData!)
}
