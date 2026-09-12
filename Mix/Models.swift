// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Aayan Agarwal

import Foundation

enum MixIdentity {
    static let appBundleID = "com.aayanagarwal.mix"
    /// Prefix of every aggregate device Mix creates, so it can filter its own
    /// devices back out of the picker.
    static let aggregatePrefix = "com.aayanagarwal.mix.tap."
}

struct MixerSnapshot: Codable, Equatable {
    var systemOutput: DeviceInfo
    var systemInput: DeviceInfo
    var systemVolume: Float
    var systemMuted: Bool
    var systemInputVolume: Float?
    var outputs: [DeviceInfo]
    var inputs: [DeviceInfo]
    var apps: [AppRow]
    var permissionGranted: Bool
}

struct DeviceInfo: Codable, Equatable, Identifiable, Hashable {
    var uid: String
    var name: String
    var transport: DeviceTransport
    var isAirPlay: Bool
    var isBluetooth: Bool
    var isAlive: Bool

    var id: String { uid }
}

enum DeviceTransport: String, Codable, Equatable {
    case builtIn
    case bluetooth
    case usb
    case hdmi
    case airplay
    case aggregate
    case other
}

struct AppRow: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var volume: Float
    var muted: Bool
    var outputUID: String?
    var destinationName: String
    var destinationIsFallback: Bool
    var error: String?

    var id: String { bundleID }
}

enum MixCommand: Codable {
    case setSystemVolume(Float)
    case setSystemMuted(Bool)
    case setDefaultOutput(String)
    case setDefaultInput(String)
    case setSystemInputVolume(Float)
    case setAppVolume(bundleID: String, volume: Float)
    case setAppMuted(bundleID: String, muted: Bool)
    case setAppOutput(bundleID: String, uid: String?)
}

struct MixCommandResult: Codable {
    var snapshot: MixerSnapshot
}

struct SavedRoute: Codable, Equatable {
    var volume: Float
    var muted: Bool
    var outputUID: String?
}

struct SavedStore: Codable, Equatable {
    var apps: [String: SavedRoute]
    var didRequestAudioPermission: Bool

    static let empty = SavedStore(apps: [:], didRequestAudioPermission: false)
}

extension SavedRoute {
    var isManaged: Bool {
        volume != 1 || muted || outputUID != nil
    }
}

extension DeviceInfo {
    static let noOutput = DeviceInfo(
        uid: "",
        name: "No Output Device",
        transport: .other,
        isAirPlay: false,
        isBluetooth: false,
        isAlive: false
    )

    static let noInput = DeviceInfo(
        uid: "",
        name: "No Input Device",
        transport: .other,
        isAirPlay: false,
        isBluetooth: false,
        isAlive: false
    )
}

extension MixerSnapshot {
    /// The state before the engine has read the HAL even once. Every field is
    /// literally true: no devices known, no apps managed. Never fake rows.
    static let empty = MixerSnapshot(
        systemOutput: .noOutput,
        systemInput: .noInput,
        systemVolume: 0,
        systemMuted: false,
        systemInputVolume: nil,
        outputs: [],
        inputs: [],
        apps: [],
        permissionGranted: true
    )
}