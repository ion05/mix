// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Aayan Agarwal

import Foundation
import CoreAudio

/// Owns every process tap and aggregate device Mix creates. It lives in the app
/// process: while Mix is in the menu bar the engine is mixing, and when Mix
/// quits `shutdown()` tears every route down so nothing survives the process.
final class AudioEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aayanagarwal.mix.engine")
    private let persistence = Persistence()
    private var routes: [String: TapRoute] = [:]
    private var listeners: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var watchedDevices: Set<AudioObjectID> = []
    private var lastSnapshot = MixerSnapshot.empty
    private var isShutDown = false
    /// Device UIDs seen on the last refresh. Nil until the first one, so the
    /// devices present at launch never count as just connected.
    private var knownUIDs: Set<String>?
    /// When each device connected, tracked per side so undoing an output
    /// takeover doesn't stop Mix from also undoing the input one.
    private var outputArrivals: [String: Date] = [:]
    private var inputArrivals: [String: Date] = [:]
    private var lastOutputUID: String?
    private var lastInputUID: String?
    /// How long after connecting a device counts as "just connected".
    private let arrivalWindow: TimeInterval = 3

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.installListeners()
            self.refresh()
        }
    }

    func snapshot() async -> MixerSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !self.isShutDown else {
                    continuation.resume(returning: .empty)
                    return
                }
                self.refresh()
                continuation.resume(returning: self.lastSnapshot)
            }
        }
    }

    func apply(_ command: MixCommand) async -> MixerSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !self.isShutDown else {
                    continuation.resume(returning: .empty)
                    return
                }
                self.handle(command)
                self.refresh()
                continuation.resume(returning: self.lastSnapshot)
            }
        }
    }

    /// Stops all mixing. Saved routes stay on disk so the next launch restores
    /// them, but no tap, aggregate device, or HAL listener outlives this call.
    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.shutdownLocked()
                continuation.resume()
            }
        }
    }

    /// Same as `shutdown()`, for `applicationWillTerminate` where the process is
    /// about to die and there is no time left to await anything.
    func shutdownSynchronously() {
        queue.sync { shutdownLocked() }
    }

    private func shutdownLocked() {
        guard !isShutDown else { return }
        isShutDown = true
        teardownAll()
        lastSnapshot = .empty
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
            outputArrivals.removeValue(forKey: uid)
            try? DeviceCatalog.setDefaultOutput(uid: uid)
        case .setDefaultInput(let uid):
            inputArrivals.removeValue(forKey: uid)
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

    private func refresh() {
        guard !isShutDown else { return }
        holdSystemDevices()
        let grouped = ProcessCatalog.grouped()
        let systemOutID = DeviceCatalog.defaultOutput()
        let systemInID = DeviceCatalog.defaultInput()
        let systemOut = DeviceCatalog.info(of: systemOutID) ?? .noOutput
        let systemIn = DeviceCatalog.info(of: systemInID) ?? .noInput
        let systemUID = systemOut.uid
        lastOutputUID = systemOut.uid.isEmpty ? nil : systemOut.uid
        lastInputUID = systemIn.uid.isEmpty ? nil : systemIn.uid

        let saved = persistence.snapshot
        for (bundleID, processes) in grouped where processes.contains(where: \.isPlayingOutput) {
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
            permissionGranted: !tapDenied
        )
    }

    /// macOS makes a newly connected device the system output (and often the
    /// input). With "Keep System Audio When Devices Connect" on, a default that
    /// moved to a device which appeared moments ago is put back where it was.
    // ponytail: arrival-window heuristic. Picking a device in Control Center that
    // connects it (AirPods, Continuity mic) is undone once; picking it again sticks.
    private func holdSystemDevices() {
        let now = Date()
        let current = Set(DeviceCatalog.allDevices().compactMap(DeviceCatalog.uid(of:)))
        if let known = knownUIDs {
            for uid in current.subtracting(known) {
                outputArrivals[uid] = now
                inputArrivals[uid] = now
            }
        }
        knownUIDs = current
        outputArrivals = outputArrivals.filter { now.timeIntervalSince($0.value) < arrivalWindow }
        inputArrivals = inputArrivals.filter { now.timeIntervalSince($0.value) < arrivalWindow }

        guard UserDefaults.standard.bool(forKey: MixIdentity.holdSystemDevicesKey) else { return }
        restore(DeviceCatalog.defaultOutput(), to: lastOutputUID, arrivals: &outputArrivals, set: DeviceCatalog.setDefaultOutput(uid:))
        restore(DeviceCatalog.defaultInput(), to: lastInputUID, arrivals: &inputArrivals, set: DeviceCatalog.setDefaultInput(uid:))
    }

    private func restore(
        _ device: AudioObjectID,
        to previous: String?,
        arrivals: inout [String: Date],
        set: (String) throws -> Void
    ) {
        guard let previous, let uid = DeviceCatalog.uid(of: device), uid != previous,
              arrivals[uid] != nil,
              let old = DeviceCatalog.device(uid: previous), DeviceCatalog.isAlive(old) else { return }
        try? set(previous)
        // Once per arrival, so a second pick sticks and nothing ping-pongs.
        arrivals.removeValue(forKey: uid)
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
        // Apps that actually have audio right now, plus anything Mix is already
        // routing. A saved route for an app that is not running stays on disk
        // and comes back with the app; it never gets a row of its own here.
        var bundleIDs = Set(grouped.filter { $0.value.contains(where: \.isPlayingOutput) }.keys)
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
            self?.refresh()
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

}