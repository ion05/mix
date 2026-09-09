import Foundation
import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class MixerStore: ObservableObject {
    static let shared = MixerStore()
    @Published var snapshot: MixerSnapshot? = .shellPreview()
    @Published var agentReady = false
    @Published var showPermissionRepair = false

    private let client = AudioClient()
    private var localEngine: AudioEngine?
    private var timer: Timer?

    func start() {
        ensureServices()
        enableLoginOnFirstLaunch()
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func ensureServices() {
        let agent = SMAppService.agent(plistName: MixXPC.agentPlist)
        if agent.status != .enabled {
            Task { try? await agent.register() }
        }
        client.connect()
    }

    func refresh() async {
        if let engine = localEngine {
            await pullLocal(engine)
            Task { await self.promoteAgentIfAvailable() }
            return
        }
        if let snapshot = await client.fetchSnapshot() {
            applySnapshot(snapshot)
            agentReady = true
            return
        }
        agentReady = false
        ensureServices()
        let engine = AudioEngine()
        engine.start()
        localEngine = engine
        await pullLocal(engine)
    }

    private func pullLocal(_ engine: AudioEngine) async {
        let snapshot: MixerSnapshot? = await withCheckedContinuation { continuation in
            engine.fetchSnapshot { data in
                continuation.resume(returning: try? JSONDecoder().decode(MixerSnapshot.self, from: data))
            }
        }
        if let snapshot {
            applySnapshot(snapshot)
        }
    }

    private func promoteAgentIfAvailable() async {
        guard let snapshot = await client.fetchSnapshot() else { return }
        if let localEngine {
            localEngine.requestQuit {}
            self.localEngine = nil
        }
        applySnapshot(snapshot)
        agentReady = true
    }

    func apply(_ command: MixCommand) {
        Task {
            if agentReady, let snapshot = await client.apply(command) {
                applySnapshot(snapshot)
                return
            }
            guard let engine = localEngine, let data = try? JSONEncoder().encode(command) else { return }
            let snapshot: MixerSnapshot? = await withCheckedContinuation { continuation in
                engine.applyCommand(data) { data in
                    continuation.resume(returning: try? JSONDecoder().decode(MixerSnapshot.self, from: data))
                }
            }
            if let snapshot {
                applySnapshot(snapshot)
            }
        }
    }

    private func applySnapshot(_ snapshot: MixerSnapshot) {
        self.snapshot = snapshot
        showPermissionRepair = !snapshot.permissionGranted
            || snapshot.apps.contains { $0.error == "Could not route audio" }
    }

    func enableLoginOnFirstLaunch() {
        let key = "mix.loginPrompted"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled {
            Task { try? await SMAppService.mainApp.register() }
        }
    }

    var loginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func toggleLogin() {
        Task {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try await SMAppService.mainApp.unregister()
                } else {
                    try await SMAppService.mainApp.register()
                }
            } catch {
                NSLog("Mix login item: \(error)")
            }
            objectWillChange.send()
        }
    }

    func repairPermission() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func quitMix() {
        Task {
            await client.quitAgent()
            localEngine?.requestQuit {}
            localEngine = nil
            try? await SMAppService.agent(plistName: MixXPC.agentPlist).unregister()
            NSApp.terminate(nil)
        }
    }

    func promptAudioIfNeeded() {
        let key = "mix.didPromptAudio"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "Mix needs System Audio Recording"
        alert.informativeText = "Mix needs System Audio Recording to change per-app volume. macOS will ask the next time Mix taps an app."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }

    func setSystemVolume(_ value: Float) {
        apply(.setSystemVolume(value))
    }

    func icon(for bundleID: String) -> NSImage {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            icon.size = NSSize(width: 28, height: 28)
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 28, height: 28)
            return icon
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }
}

enum MixPalette {
    static let fallback = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    static let connected = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let danger = Color(red: 1, green: 59 / 255, blue: 48 / 255)
    static let info = Color(red: 100 / 255, green: 210 / 255, blue: 1)
}
