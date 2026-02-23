import AVFoundation
import CoreAudio
import AudioToolbox

final class AudioEngine {
    private var engine: AVAudioEngine?
    private var aggregateDeviceID: AudioDeviceID = 0

    var volume: Float {
        get { engine?.mainMixerNode.outputVolume ?? 1.0 }
        set { engine?.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    // MARK: - Lifecycle

    func start(blackHoleUID: String, dellUID: String) throws {
        let aggID = try createAggregateDevice(inputUID: blackHoleUID, outputUID: dellUID)
        aggregateDeviceID = aggID

        let engine = AVAudioEngine()
        self.engine = engine

        // Set aggregate as the engine's audio device
        let outputUnit = engine.outputNode.audioUnit!
        var deviceID = aggID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw EngineError.cannotSetDevice(status)
        }

        // Connect input → mixer → output
        // Use each node's native format so the mixer handles channel conversion
        // (BlackHole 16ch → 2ch Dell)
        let input = engine.inputNode
        let mixer = engine.mainMixerNode
        let inputFormat = input.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)

        engine.connect(input, to: mixer, format: inputFormat)
        engine.connect(mixer, to: engine.outputNode, format: outputFormat)

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine?.stop()
        engine = nil

        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
    }

    func restart(blackHoleUID: String, dellUID: String) throws {
        stop()
        try start(blackHoleUID: blackHoleUID, dellUID: dellUID)
    }

    // MARK: - Aggregate Device

    private func createAggregateDevice(inputUID: String, outputUID: String) throws -> AudioDeviceID {
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: "com.local.VolumeBuddy.Aggregate",
            kAudioAggregateDeviceNameKey as String: "VolumeBuddy Aggregate",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: inputUID],
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

    // MARK: - Errors

    enum EngineError: LocalizedError {
        case cannotCreateAggregate(OSStatus)
        case cannotSetDevice(OSStatus)

        var errorDescription: String? {
            switch self {
            case .cannotCreateAggregate(let s): return "Failed to create aggregate device (OSStatus \(s))"
            case .cannotSetDevice(let s): return "Failed to set audio device (OSStatus \(s))"
            }
        }
    }
}
