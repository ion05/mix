import Foundation

enum MixXPC {
    static let machService = "com.aayanagarwal.mix.audio"
    static let agentPlist = "com.aayanagarwal.mix.audio.plist"
    static let appBundleID = "com.aayanagarwal.mix"
    static let agentBundleID = "com.aayanagarwal.mix.audio"
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
    var loginItemEnabled: Bool
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
    var destinationIsBluetooth: Bool
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

extension MixerSnapshot {
    static func shellPreview() -> MixerSnapshot {
        let speakers = DeviceInfo(
            uid: "mix.preview.speakers",
            name: "MacBook Pro Speakers",
            transport: .builtIn,
            isAirPlay: false,
            isBluetooth: false,
            isAlive: true
        )
        let airpods = DeviceInfo(
            uid: "mix.preview.airpods",
            name: "AirPods Pro",
            transport: .bluetooth,
            isAirPlay: false,
            isBluetooth: true,
            isAlive: true
        )
        let mic = DeviceInfo(
            uid: "mix.preview.mic",
            name: "MacBook Pro Microphone",
            transport: .builtIn,
            isAirPlay: false,
            isBluetooth: false,
            isAlive: true
        )
        return MixerSnapshot(
            systemOutput: speakers,
            systemInput: mic,
            systemVolume: 0.62,
            systemMuted: false,
            systemInputVolume: 0.8,
            outputs: [speakers, airpods],
            inputs: [mic],
            apps: [
                AppRow(
                    bundleID: "us.zoom.xos",
                    name: "Zoom",
                    volume: 0.4,
                    muted: false,
                    outputUID: airpods.uid,
                    destinationName: "AirPods Pro",
                    destinationIsFallback: false,
                    destinationIsBluetooth: true,
                    error: nil
                ),
                AppRow(
                    bundleID: "com.spotify.client",
                    name: "Spotify",
                    volume: 0.78,
                    muted: false,
                    outputUID: nil,
                    destinationName: "MacBook Pro Speakers",
                    destinationIsFallback: false,
                    destinationIsBluetooth: false,
                    error: nil
                )
            ],
            permissionGranted: true,
            loginItemEnabled: false
        )
    }
}
