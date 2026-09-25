// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Aayan Agarwal

import AppKit

/// Offers to move Mix into /Applications when it runs from anywhere else,
/// usually straight off the installer disk image, and ejects that disk once
/// the moved copy relaunches.
@MainActor
enum MoveToApplications {
    private static let declinedKey = "mix.declinedMoveToApplications"

    /// Returns true when Mix is quitting so the moved copy can take over.
    static func offerIfNeeded() -> Bool {
        #if DEBUG
        // Xcode runs Mix out of DerivedData; never offer to move a dev build.
        return false
        #else
        let source = originalBundleURL()
        guard !isInApplications(source),
              !UserDefaults.standard.bool(forKey: declinedKey) else { return false }

        // Mix has no Dock icon, so bring it forward or the alert opens behind.
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Mix to Applications?"
        alert.informativeText = "Mix will move itself to your Applications folder, relaunch from there, and eject the installer."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Do Not Move")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: declinedKey)
            return false
        }

        do {
            try move(from: source)
            return true
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Mix could not move itself to Applications"
            failure.runModal()
            return false
        }
        #endif
    }

    private static func isInApplications(_ url: URL) -> Bool {
        let folders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        return folders.contains { url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    private static func move(from source: URL) throws {
        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)

        // An older Mix still running from /Applications would otherwise keep
        // its menu bar item next to the new one.
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? MixIdentity.appBundleID)
        where app.processIdentifier != me {
            app.terminate()
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: source, to: destination)

        // Off a disk image the original can't be deleted, so eject the disk;
        // anywhere else (Downloads, say) move the original to the Trash.
        let installerDisk = readOnlyVolume(containing: source)
        if installerDisk == nil {
            try? fileManager.trashItem(at: source, resultingItemURL: nil)
        }
        try relaunch(destination, ejecting: installerDisk)
    }

    private static func readOnlyVolume(containing url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey])
        guard values?.volumeIsReadOnly == true else { return nil }
        return values?.volume
    }

    /// Waits for this process to exit, ejects the installer disk, then opens
    /// the moved copy. Paths travel as environment variables, never as script.
    private static func relaunch(_ app: URL, ejecting disk: URL?) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", """
            while /bin/kill -0 "$MIX_PID" 2>/dev/null; do /bin/sleep 0.2; done
            if [ -n "$MIX_DISK" ]; then /usr/bin/hdiutil detach -quiet "$MIX_DISK"; fi
            /usr/bin/open "$MIX_APP"
            """]
        task.environment = [
            "MIX_PID": String(ProcessInfo.processInfo.processIdentifier),
            "MIX_APP": app.path,
            "MIX_DISK": disk?.path ?? ""
        ]
        try task.run()
        NSApp.terminate(nil)
    }

    /// Where Mix really lives. Gatekeeper runs a freshly downloaded app from a
    /// randomized read-only copy (App Translocation), whose path would hide
    /// both the disk image and whether Mix is already in Applications.
    private static func originalBundleURL() -> URL {
        let url = Bundle.main.bundleURL
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutableRawPointer?) -> UInt8
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutableRawPointer?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        var translocated = false
        guard unsafeBitCast(isSymbol, to: IsTranslocated.self)(url as CFURL, &translocated, nil) != 0,
              translocated,
              let original = unsafeBitCast(originalSymbol, to: OriginalPath.self)(url as CFURL, nil) else { return url }
        return original.takeRetainedValue() as URL
    }
}
