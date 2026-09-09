import Foundation
import CoreAudio
import os

final class TapRoute {
    let bundleID: String
    private(set) var volume: Float
    private(set) var muted: Bool
    private(set) var outputUID: String?
    private(set) var assignedUID: String?
    private(set) var isActive = false
    private(set) var error: String?
    private var lastProcessIDs: [AudioObjectID] = []
    private var lastSampleRate: Float64 = 0

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID = UUID()
    private let gain = OSAllocatedUnfairLock(initialState: Float(1))

    init(bundleID: String, volume: Float, muted: Bool, outputUID: String?) {
        self.bundleID = bundleID
        self.volume = volume
        self.muted = muted
        self.outputUID = outputUID
        applyGain()
    }

    deinit {
        teardown()
    }

    var needsAudio: Bool {
        volume != 1 || muted || outputUID != nil
    }

    func setVolume(_ value: Float) {
        volume = min(1, max(0, value))
        applyGain()
    }

    func setMuted(_ value: Bool) {
        muted = value
        applyGain()
    }

    func matches(processIDs: [AudioObjectID], outputUID: String, sampleRate: Float64) -> Bool {
        isActive
            && error == nil
            && assignedUID == outputUID
            && lastProcessIDs == processIDs
            && lastSampleRate == sampleRate
    }

    func setOutputUID(_ uid: String?) {
        outputUID = uid
    }

    func activate(processIDs: [AudioObjectID], preferredUID: String?, systemUID: String) {
        teardown()
        error = nil
        isActive = false
        let ids = processIDs.sorted()
        guard !ids.isEmpty else {
            error = "App is not producing audio yet"
            return
        }
        let targetUID = preferredUID ?? systemUID
        guard let outputDevice = DeviceCatalog.device(uid: targetUID) else {
            error = "Output device is gone"
            return
        }
        if DeviceCatalog.info(of: outputDevice)?.isAirPlay == true {
            error = "System output is AirPlay — Mix can’t clock this route"
            return
        }
        do {
            try createTap(processIDs: ids, outputDevice: outputDevice, outputUID: targetUID)
        } catch {
            self.error = "Could not route audio"
            teardown()
        }
    }

    func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isActive = false
        lastProcessIDs = []
        lastSampleRate = 0
        assignedUID = nil
    }

    private func applyGain() {
        gain.withLock { $0 = muted ? 0 : volume }
    }

    private func createTap(processIDs: [AudioObjectID], outputDevice: AudioObjectID, outputUID: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        tapUUID = UUID()
        description.uuid = tapUUID
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "Mix \(bundleID)"

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapErr == noErr, newTap != kAudioObjectUnknown else {
            throw HALError.status(tapErr, "create tap")
        }
        tapID = newTap

        let aggregateUID = "com.aayanagarwal.mix.tap.\(tapUUID.uuidString)"
        let aggregateName = "Mix Tap \(bundleID)"
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAgg = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newAgg)
        guard aggErr == noErr else { throw HALError.status(aggErr, "aggregate") }
        aggregateID = newAgg

        let lock = gain
        var procID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inputData, _, outputData, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let gainValue = lock.withLock { $0 }
            for (index, buffer) in buffers.enumerated() {
                guard index < inBuffers.count else { break }
                let inBuf = inBuffers[index]
                let frames = Int(buffer.mDataByteSize / 4)
                guard let outPtr = buffer.mData?.assumingMemoryBound(to: Float.self),
                      let inPtr = inBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                if gainValue == 0 {
                    memset(outPtr, 0, Int(buffer.mDataByteSize))
                } else if gainValue == 1 {
                    memcpy(outPtr, inPtr, Int(min(buffer.mDataByteSize, inBuf.mDataByteSize)))
                } else {
                    let count = min(frames, Int(inBuf.mDataByteSize / 4))
                    for i in 0..<count {
                        outPtr[i] = inPtr[i] * gainValue
                    }
                }
            }
        }
        guard ioErr == noErr, let procID else { throw HALError.status(ioErr, "ioproc") }
        ioProcID = procID
        let startErr = AudioDeviceStart(aggregateID, procID)
        guard startErr == noErr else { throw HALError.status(startErr, "start") }
        assignedUID = outputUID
        lastProcessIDs = processIDs
        lastSampleRate = DeviceCatalog.sampleRate(outputDevice)
        isActive = true
    }
}
