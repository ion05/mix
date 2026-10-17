// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Aayan Agarwal

import Foundation
import CoreAudio
import os

final class TapRoute {
    /// What the IO proc reads under one lock: where the gain is heading and
    /// where it is now. The proc walks `current` toward `target` each callback.
    struct GainState {
        var target: Float
        var current: Float
    }

    /// Seconds a full 0-to-1 gain swing takes. A duck to 25% is three quarters
    /// of that, which is the ~150 ms fade.
    static let fullSwingSeconds = 0.2

    /// The next gain after one callback of `frames` frames: at most
    /// `frames / (fullSwingSeconds * sampleRate)` closer to `to`, landing
    /// exactly on it. Without a usable sample rate it jumps straight there.
    static func rampStep(from: Float, to: Float, frames: Int, sampleRate: Float64) -> Float {
        guard sampleRate > 0 else { return to }
        let step = Float(Float64(frames) / (fullSwingSeconds * sampleRate))
        return abs(to - from) <= step ? to : (to > from ? from + step : from - step)
    }

    static func gain(volume: Float, muted: Bool, duck: Float) -> Float {
        muted ? 0 : volume * duck
    }

    let bundleID: String
    private(set) var volume: Float
    private(set) var muted: Bool
    private(set) var outputUID: String?
    /// Temporary ducking, never persisted. 1 is no duck.
    private(set) var duck: Float = 1
    /// Keeps a route that only exists for the duck alive until Mix lets go.
    var duckHold = false
    /// Where the app was already playing, for a route that exists only to duck
    /// it; the replay goes there instead of the system output.
    var duckUID: String?
    private(set) var assignedUID: String?
    private(set) var isActive = false
    private(set) var error: String?
    private var lastProcessIDs: [AudioObjectID] = []
    private var lastSampleRate: Float64 = 0

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID = UUID()
    private let gain = OSAllocatedUnfairLock(initialState: GainState(target: 1, current: 1))

    init(bundleID: String, volume: Float, muted: Bool, outputUID: String?) {
        self.bundleID = bundleID
        self.volume = volume
        self.muted = muted
        self.outputUID = outputUID
        let initial = Self.gain(volume: volume, muted: muted, duck: 1)
        gain.withLock { $0 = GainState(target: initial, current: initial) }
    }

    deinit {
        teardown()
    }

    var needsAudio: Bool {
        volume != 1 || muted || outputUID != nil || duckHold
    }

    func setDuck(_ value: Float) {
        duck = value
        applyGain()
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
        let target = Self.gain(volume: volume, muted: muted, duck: duck)
        gain.withLock { $0.target = target }
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

        let aggregateUID = MixIdentity.aggregatePrefix + tapUUID.uuidString
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

        let sampleRate = DeviceCatalog.sampleRate(outputDevice)
        let lock = gain
        var procID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inputData, _, outputData, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let firstBytes = buffers.first.map { Int($0.mDataByteSize) } ?? 0
            let firstChannels = buffers.first.map { max(1, Int($0.mNumberChannels)) } ?? 1
            let (from, to) = lock.withLock { state -> (Float, Float) in
                let from = state.current
                state.current = Self.rampStep(
                    from: from, to: state.target,
                    frames: firstBytes / 4 / firstChannels, sampleRate: sampleRate
                )
                return (from, state.current)
            }
            for (index, buffer) in buffers.enumerated() {
                guard index < inBuffers.count else { break }
                let inBuf = inBuffers[index]
                let samples = Int(buffer.mDataByteSize / 4)
                guard let outPtr = buffer.mData?.assumingMemoryBound(to: Float.self),
                      let inPtr = inBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                if from == 0 && to == 0 {
                    memset(outPtr, 0, Int(buffer.mDataByteSize))
                } else if from == 1 && to == 1 {
                    memcpy(outPtr, inPtr, Int(min(buffer.mDataByteSize, inBuf.mDataByteSize)))
                } else {
                    let count = min(samples, Int(inBuf.mDataByteSize / 4))
                    let channels = max(1, Int(buffer.mNumberChannels))
                    let frames = Float(max(1, samples / channels))
                    let slope = (to - from) / frames
                    for i in 0..<count {
                        outPtr[i] = inPtr[i] * (from + slope * Float(i / channels))
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
        lastSampleRate = sampleRate
        isActive = true
    }
}