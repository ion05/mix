import AppKit
import SwiftUI

@main
struct MixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var store = MixerStore.shared

    var body: some Scene {
        MenuBarExtra {
            MixerPopover()
                .environmentObject(store)
                .onAppear {
                    MixWindowStyler.styleExtraWindows()
                    store.promptAudioIfNeeded()
                }
        } label: {
            Image(systemName: store.snapshot?.systemMuted == true ? "speaker.slash" : "speaker.wave.2")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: MixerStore { MixerStore.shared }
    private var scrollMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.start()
        installScrollWheel()
        MixWindowStyler.styleExtraWindows()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installScrollWheel() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let overExtra = event.window?.level == .statusBar
                || event.window?.className.contains("StatusBar") == true
            if overExtra {
                let delta = Float(event.scrollingDeltaY)
                if abs(delta) > 0.1, let current = self.store.snapshot?.systemVolume {
                    let next = min(1, max(0, current + (event.isDirectionInvertedFromDevice ? -delta : delta) / 80))
                    self.store.setSystemVolume(next)
                }
            }
            return event
        }
    }
}

enum MixWindowStyler {
    static func styleExtraWindows() {
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovable = false
                window.backgroundColor = .clear
                window.isOpaque = false
                window.hasShadow = true
            }
        }
    }
}
