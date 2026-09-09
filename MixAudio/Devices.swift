import Foundation
import CoreAudio

enum DeviceCatalog {
    static func allDevices() -> [AudioObjectID] {
        (try? HAL.getArray(AudioObjectID.system, kAudioHardwarePropertyDevices)) ?? []
    }

    static func defaultOutput() -> AudioObjectID {
        (try? HAL.get(AudioObjectID.system, kAudioHardwarePropertyDefaultOutputDevice)) ?? 0
    }

    static func defaultInput() -> AudioObjectID {
        (try? HAL.get(AudioObjectID.system, kAudioHardwarePropertyDefaultInputDevice)) ?? 0
    }

    static func uid(of device: AudioObjectID) -> String? {
        try? HAL.getCFString(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(of device: AudioObjectID) -> String {
        (try? HAL.getCFString(device, kAudioObjectPropertyName)) ?? "Audio device"
    }

    static func transport(of device: AudioObjectID) -> UInt32 {
        (try? HAL.get(device, kAudioDevicePropertyTransportType)) ?? kAudioDeviceTransportTypeUnknown
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        ((try? HAL.get(device, kAudioDevicePropertyDeviceIsAlive)) as UInt32?) ?? 0 != 0
    }

    static func hasOutput(_ device: AudioObjectID) -> Bool {
        streamCount(device, kAudioObjectPropertyScopeOutput) > 0
    }

    static func hasInput(_ device: AudioObjectID) -> Bool {
        streamCount(device, kAudioObjectPropertyScopeInput) > 0
    }

    static func streamCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        (try? HAL.getArray(device, kAudioDevicePropertyStreams, scope: scope) as [AudioObjectID])?.count ?? 0
    }

    static func info(of device: AudioObjectID) -> DeviceInfo? {
        guard let uid = uid(of: device) else { return nil }
        let transportCode = transport(of: device)
        let transport = classify(transportCode)
        return DeviceInfo(
            uid: uid,
            name: name(of: device),
            transport: transport,
            isAirPlay: transport == .airplay,
            isBluetooth: transport == .bluetooth,
            isAlive: isAlive(device)
        )
    }

    static func device(uid: String) -> AudioObjectID? {
        allDevices().first { self.uid(of: $0) == uid }
    }

    static func classify(_ transport: UInt32) -> DeviceTransport {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .hdmi
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        default: return .other
        }
    }

    static func outputsForPicker() -> [DeviceInfo] {
        allDevices().compactMap { device -> DeviceInfo? in
            guard hasOutput(device), isAlive(device), let info = info(of: device) else { return nil }
            if info.isAirPlay { return nil }
            if info.transport == .aggregate { return nil }
            if info.uid.hasPrefix("com.aayanagarwal.mix") { return nil }
            return info
        }
    }

    static func inputs() -> [DeviceInfo] {
        allDevices().compactMap { device in
            guard hasInput(device), isAlive(device) else { return nil }
            return info(of: device)
        }
    }

    static func setDefaultOutput(uid: String) throws {
        guard let device = device(uid: uid) else { throw HALError.missing }
        try HAL.set(AudioObjectID.system, kAudioHardwarePropertyDefaultOutputDevice, device)
    }

    static func setDefaultInput(uid: String) throws {
        guard let device = device(uid: uid) else { throw HALError.missing }
        try HAL.set(AudioObjectID.system, kAudioHardwarePropertyDefaultInputDevice, device)
    }

    static func volume(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Float {
        if existsVolume(device, scope, kAudioObjectPropertyElementMain) {
            return (try? HAL.get(device, kAudioDevicePropertyVolumeScalar, scope: scope)) ?? 0
        }
        let channels = outputChannels(device, scope)
        let values = channels.compactMap { channel -> Float? in
            var addr = HAL.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: channel)
            var size = UInt32(MemoryLayout<Float32>.size)
            var value: Float32 = 0
            let err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
            return err == noErr ? value : nil
        }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    static func setVolume(_ value: Float, of device: AudioObjectID, scope: AudioObjectPropertyScope) {
        let clamped = min(1, max(0, value))
        if existsVolume(device, scope, kAudioObjectPropertyElementMain) {
            try? HAL.set(device, kAudioDevicePropertyVolumeScalar, Float32(clamped), scope: scope)
            return
        }
        for channel in outputChannels(device, scope) {
            var addr = HAL.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: channel)
            var copy = Float32(clamped)
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &copy)
        }
    }

    static func isMuted(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        ((try? HAL.get(device, kAudioDevicePropertyMute, scope: scope)) as UInt32?) ?? 0 != 0
    }

    static func setMuted(_ muted: Bool, of device: AudioObjectID, scope: AudioObjectPropertyScope) {
        try? HAL.set(device, kAudioDevicePropertyMute, UInt32(muted ? 1 : 0), scope: scope)
    }

    static func sampleRate(_ device: AudioObjectID) -> Float64 {
        (try? HAL.get(device, kAudioDevicePropertyNominalSampleRate)) ?? 0
    }

    static func isHFPRate(_ rate: Float64) -> Bool {
        rate > 0 && rate <= 24_000
    }

    private static func existsVolume(
        _ device: AudioObjectID,
        _ scope: AudioObjectPropertyScope,
        _ element: AudioObjectPropertyElement
    ) -> Bool {
        var addr = HAL.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
        return AudioObjectHasProperty(device, &addr)
    }

    private static func outputChannels(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectPropertyElement] {
        (1...8).filter { channel in
            var addr = HAL.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: channel)
            return AudioObjectHasProperty(device, &addr)
        }
    }
}
