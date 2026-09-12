import Foundation
import AppKit
import ServiceManagement
import SwiftUI

/// Single source of truth for the popover. Mix runs one process, so the engine
/// is owned here and lives exactly as long as the menu bar item does.
@MainActor
final class MixerStore: ObservableObject {
    static let shared = MixerStore()

    @Published private(set) var snapshot: MixerSnapshot = .empty
    @Published private(set) var showPermissionRepair = false
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    /// Non-nil when a Launch at Login change failed. Surfaced in the menu so a
    /// registration failure can never pass silently again.
    @Published private(set) var loginError: String?

    private let engine = AudioEngine()
    private var timer: Timer?
    private var isQuitting = false

    func start() {
        engine.start()
        enableLoginOnFirstLaunch()
        Task { await refresh() }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() async {
        guard !isQuitting else { return }
        applySnapshot(await engine.snapshot())
    }

    func apply(_ command: MixCommand) {
        guard !isQuitting else { return }
        Task { applySnapshot(await engine.apply(command)) }
    }

    func setSystemVolume(_ value: Float) {
        apply(.setSystemVolume(value))
    }

    private func applySnapshot(_ snapshot: MixerSnapshot) {
        guard !isQuitting else { return }
        self.snapshot = snapshot
        showPermissionRepair = !snapshot.permissionGranted
            || snapshot.apps.contains { $0.error == "Could not route audio" }
    }

    // MARK: - Quitting

    /// The only way to stop Mix. It tears down every tap and then terminates,
    /// so quitting removes the menu bar item and stops the mixing together.
    /// Nothing is left running in the background.
    func quitMix() {
        guard !isQuitting else { return }
        isQuitting = true
        timer?.invalidate()
        timer = nil
        Task {
            await engine.shutdown()
            NSApp.terminate(nil)
        }
    }

    /// Backstop for a termination Mix did not initiate, such as a logout or a
    /// kill from Activity Monitor.
    func tearDownForTermination() {
        isQuitting = true
        timer?.invalidate()
        timer = nil
        engine.shutdownSynchronously()
    }

    // MARK: - Launch at Login

    private func enableLoginOnFirstLaunch() {
        let key = "mix.loginPrompted"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard SMAppService.mainApp.status != .enabled else { return }
        setLogin(enabled: true)
    }

    func toggleLogin() {
        setLogin(enabled: SMAppService.mainApp.status != .enabled)
    }

    private func setLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            NSLog("Mix: Launch at Login \(enabled ? "register" : "unregister") failed: \(error)")
        }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Permission

    func repairPermission() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ].compactMap(URL.init(string:))
        guard let url = urls.first else { return }
        NSWorkspace.shared.open(url)
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

    // MARK: - Icons

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
