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
            Image(systemName: store.snapshot.systemMuted ? "speaker.slash" : "speaker.wave.2")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var scrollMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MixerStore.shared.start()
        installScrollWheel()
        MixWindowStyler.styleExtraWindows()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Mix is only ever active while it is in the menu bar, so termination has
    /// to leave the audio graph exactly as it found it.
    func applicationWillTerminate(_ notification: Notification) {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        MainActor.assumeIsolated {
            MixerStore.shared.tearDownForTermination()
        }
    }

    private func installScrollWheel() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard Self.isOverMenuBarExtra(event) else { return event }
            let delta = Float(event.scrollingDeltaY)
            guard abs(delta) > 0.1 else { return event }
            let inverted = event.isDirectionInvertedFromDevice
            // AppKit delivers event monitors on the main thread, so the store's
            // main-actor state is safe to touch here once that is made explicit.
            MainActor.assumeIsolated {
                let store = MixerStore.shared
                let step = (inverted ? -delta : delta) / 80
                store.setSystemVolume(min(1, max(0, store.snapshot.systemVolume + step)))
            }
            return event
        }
    }

    private static func isOverMenuBarExtra(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        return window.level == .statusBar || window.className.contains("StatusBar")
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
