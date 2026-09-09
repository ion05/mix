import Foundation
import CoreAudio
import AppKit
import ServiceManagement

final class AudioEngine: NSObject, MixAudioServing {
    private let queue = DispatchQueue(label: "com.aayanagarwal.mix.engine")
    private let persistence = Persistence()
    private var routes: [String: TapRoute] = [:]
    private var listeners: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var watchedDevices: Set<AudioObjectID> = []
    private var lastSnapshot = MixerSnapshot.shellPreview()
    private var cleanQuit = false
    private var uiAlive = false

    override init() {
        super.init()
        queue.async { [weak self] in
            self?.installListeners()
            self?.refresh(reason: "launch")
        }
    }

    func start() {
        queue.async { [weak self] in
            self?.refresh(reason: "start")
        }
    }

    func fetchSnapshot(withReply reply: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.uiAlive = true
            self.refresh(reason: "snapshot")
            reply(self.encode(self.lastSnapshot))
        }
    }

    func applyCommand(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if let command = try? JSONDecoder().decode(MixCommand.self, from: data) {
                self.handle(command)
            }
            self.refresh(reason: "command")
            reply(self.encode(self.lastSnapshot))
        }
    }

    func requestQuit(_ reply: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cleanQuit = true
            self.teardownAll()
            reply()
            guard Bundle.main.bundleIdentifier == MixXPC.agentBundleID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                exit(0)
            }
        }
    }

    func ping(_ reply: @escaping () -> Void) {
        queue.async { [weak self] in
            self?.uiAlive = true
            reply()
        }
    }

    func uiDidDisconnect() {
        queue.async { [weak self] in
            guard let self, !self.cleanQuit else { return }
            self.uiAlive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.queue.async {
                    guard !self.cleanQuit, !self.uiAlive else { return }
                    self.relaunchMix()
                }
            }
        }
    }

    private func handle(_ command: MixCommand) {
        switch command {
        case .setSystemVolume(let value):
            let device = DeviceCatalog.defaultOutput()
            DeviceCatalog.setVolume(value, of: device, scope: kAudioObjectPropertyScopeOutput)
        case .setSystemMuted(let muted):
            let device = DeviceCatalog.defaultOutput()
            DeviceCatalog.setMuted(muted, of: device, scope: kAudioObjectPropertyScopeOutput)
        case .setDefaultOutput(let uid):
            try? DeviceCatalog.setDefaultOutput(uid: uid)
        case .setDefaultInput(let uid):
            try? DeviceCatalog.setDefaultInput(uid: uid)
        case .setSystemInputVolume(let value):
            let device = DeviceCatalog.defaultInput()
            DeviceCatalog.setVolume(value, of: device, scope: kAudioObjectPropertyScopeInput)
        case .setAppVolume(let bundleID, let volume):
            touch(bundleID: bundleID) { route in
                route.setVolume(volume)
            }
        case .setAppMuted(let bundleID, let muted):
            touch(bundleID: bundleID) { route in
                route.setMuted(muted)
            }
        case .setAppOutput(let bundleID, let uid):
            touch(bundleID: bundleID) { route in
                route.setOutputUID(uid)
            }
            rebuildRoute(bundleID: bundleID)
        }
    }

    private func touch(bundleID: String, update: (TapRoute) -> Void) {
        let existing = routes[bundleID]
        let saved = persistence.route(for: bundleID)
        let route = existing ?? TapRoute(
            bundleID: bundleID,
            volume: saved?.volume ?? 1,
            muted: saved?.muted ?? false,
            outputUID: saved?.outputUID
        )
        update(route)
        persist(route)
        if route.needsAudio {
            routes[bundleID] = route
            if existing == nil {
                rebuildRoute(bundleID: bundleID)
            }
        } else {
            route.teardown()
            routes.removeValue(forKey: bundleID)
        }
    }

    private func persist(_ route: TapRoute) {
        persistence.upsert(
            SavedRoute(volume: route.volume, muted: route.muted, outputUID: route.outputUID),
            for: route.bundleID
        )
    }

    private func refresh(reason: String) {
        let grouped = ProcessCatalog.grouped()
        let systemOutID = DeviceCatalog.defaultOutput()
        let systemInID = DeviceCatalog.defaultInput()
        let systemOut = DeviceCatalog.info(of: systemOutID) ?? lastSnapshot.systemOutput
        let systemIn = DeviceCatalog.info(of: systemInID) ?? lastSnapshot.systemInput
        let systemUID = systemOut.uid

        let saved = persistence.snapshot
        for (bundleID, processes) in grouped where processes.contains(where: \.isRunning) {
            guard let savedRoute = saved.apps[bundleID], savedRoute.isManaged else { continue }
            if routes[bundleID] == nil {
                let route = TapRoute(
                    bundleID: bundleID,
                    volume: savedRoute.volume,
                    muted: savedRoute.muted,
                    outputUID: savedRoute.outputUID
                )
                routes[bundleID] = route
                rebuild(route: route, processes: processes, systemUID: systemUID)
            }
        }

        for route in routes.values {
            let processes = grouped[route.bundleID] ?? []
            rebuild(route: route, processes: processes, systemUID: systemUID)
        }

        var watchIDs: Set<AudioObjectID> = [systemOutID, systemInID]
        for route in routes.values {
            if let uid = route.assignedUID, let device = DeviceCatalog.device(uid: uid) {
                watchIDs.insert(device)
            }
            if let uid = route.outputUID, let device = DeviceCatalog.device(uid: uid) {
                watchIDs.insert(device)
            }
        }
        syncDeviceWatches(watchIDs)

        let tapDenied = routes.values.contains { $0.error == "Could not route audio" }
        lastSnapshot = MixerSnapshot(
            systemOutput: systemOut,
            systemInput: systemIn,
            systemVolume: DeviceCatalog.volume(of: systemOutID, scope: kAudioObjectPropertyScopeOutput),
            systemMuted: DeviceCatalog.isMuted(systemOutID, scope: kAudioObjectPropertyScopeOutput),
            systemInputVolume: DeviceCatalog.hasInput(systemInID)
                ? DeviceCatalog.volume(of: systemInID, scope: kAudioObjectPropertyScopeInput)
                : nil,
            outputs: DeviceCatalog.outputsForPicker(),
            inputs: DeviceCatalog.inputs(),
            apps: makeRows(grouped: grouped, systemOut: systemOut),
            permissionGranted: !tapDenied,
            loginItemEnabled: SMAppService.mainApp.status == .enabled
        )
        _ = reason
    }

    private func rebuildRoute(bundleID: String) {
        let grouped = ProcessCatalog.grouped()
        guard let route = routes[bundleID] else { return }
        let systemUID = DeviceCatalog.uid(of: DeviceCatalog.defaultOutput()) ?? ""
        rebuild(route: route, processes: grouped[bundleID] ?? [], systemUID: systemUID)
    }

    private func rebuild(route: TapRoute, processes: [AudioProcess], systemUID: String) {
        let ids = processes.map(\.objectID).sorted()
        let preferred = resolvedUID(for: route, systemUID: systemUID)
        let sampleRate = DeviceCatalog.device(uid: preferred).map(DeviceCatalog.sampleRate) ?? 0
        if !route.needsAudio {
            route.teardown()
            return
        }
        if route.matches(processIDs: ids, outputUID: preferred, sampleRate: sampleRate) {
            return
        }
        route.activate(
            processIDs: ids,
            preferredUID: preferred,
            systemUID: systemUID
        )
    }

    private func resolvedUID(for route: TapRoute, systemUID: String) -> String {
        guard let wanted = route.outputUID else { return systemUID }
        if let device = DeviceCatalog.device(uid: wanted), DeviceCatalog.isAlive(device) {
            return wanted
        }
        return systemUID
    }

    private func makeRows(grouped: [String: [AudioProcess]], systemOut: DeviceInfo) -> [AppRow] {
        let saved = persistence.snapshot.apps
        var bundleIDs = Set(grouped.filter { $0.value.contains(where: \.isRunning) }.keys)
        bundleIDs.formUnion(saved.keys)
        bundleIDs.formUnion(routes.keys)

        return bundleIDs.sorted { ProcessCatalog.displayName(bundleID: $0) < ProcessCatalog.displayName(bundleID: $1) }.map { bundleID in
            let route = routes[bundleID]
            let savedRoute = saved[bundleID]
            let volume = route?.volume ?? savedRoute?.volume ?? 1
            let muted = route?.muted ?? savedRoute?.muted ?? false
            let outputUID = route?.outputUID ?? savedRoute?.outputUID
            let liveUID: String
            let fallback: Bool
            if let wanted = outputUID, let device = DeviceCatalog.device(uid: wanted), DeviceCatalog.isAlive(device) {
                liveUID = wanted
                fallback = false
            } else if outputUID != nil {
                liveUID = systemOut.uid
                fallback = true
            } else {
                liveUID = systemOut.uid
                fallback = false
            }
            let dest = DeviceCatalog.device(uid: liveUID).flatMap(DeviceCatalog.info(of:)) ?? systemOut
            return AppRow(
                bundleID: bundleID,
                name: ProcessCatalog.displayName(bundleID: bundleID),
                volume: volume,
                muted: muted,
                outputUID: outputUID,
                destinationName: dest.name,
                destinationIsFallback: fallback,
                destinationIsBluetooth: dest.isBluetooth && !fallback,
                error: route?.error
            )
        }
    }

    private func installListeners() {
        listen(AudioObjectID.system, kAudioHardwarePropertyDevices, into: &listeners)
        listen(AudioObjectID.system, kAudioHardwarePropertyDefaultOutputDevice, into: &listeners)
        listen(AudioObjectID.system, kAudioHardwarePropertyDefaultInputDevice, into: &listeners)
        listen(AudioObjectID.system, kAudioHardwarePropertyProcessObjectList, into: &listeners)
    }

    @discardableResult
    private func listen(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        into storage: inout [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)]
    ) -> AudioObjectPropertyListenerBlock {
        let block = HAL.addListener(object, selector, queue: queue) { [weak self] in
            self?.refresh(reason: HAL.fourCC(selector))
        }
        storage.append((object, selector, block))
        return block
    }

    private func syncDeviceWatches(_ devices: Set<AudioObjectID>) {
        let filtered = devices.filter { $0 != 0 && $0 != kAudioObjectUnknown }
        guard filtered != watchedDevices else { return }
        for (object, selector, block) in deviceListeners {
            HAL.removeListener(object, selector, queue: queue, block: block)
        }
        deviceListeners.removeAll()
        watchedDevices = filtered
        for device in filtered {
            listen(device, kAudioDevicePropertyDeviceIsAlive, into: &deviceListeners)
            listen(device, kAudioDevicePropertyNominalSampleRate, into: &deviceListeners)
        }
    }

    private func teardownAll() {
        for route in routes.values {
            route.teardown()
        }
        routes.removeAll()
        for (object, selector, block) in listeners + deviceListeners {
            HAL.removeListener(object, selector, queue: queue, block: block)
        }
        listeners.removeAll()
        deviceListeners.removeAll()
        watchedDevices.removeAll()
    }

    private func relaunchMix() {
        guard let url = mixAppURL() else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    private func mixAppURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MixXPC.appBundleID) {
            return url
        }
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func encode(_ snapshot: MixerSnapshot) -> Data {
        (try? JSONEncoder().encode(snapshot)) ?? Data()
    }
}
