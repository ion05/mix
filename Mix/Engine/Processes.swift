import Foundation
import CoreAudio
import AppKit
import Darwin
import os

struct AudioProcess: Equatable {
    var objectID: AudioObjectID
    var pid: pid_t
    /// The identifier of the application that OWNS this process, which is not
    /// always the one CoreAudio reports. See `ProcessCatalog.owningBundleID`.
    var bundleID: String
    /// True only while the process is doing output IO. Mix routes output, so a
    /// process that is merely listening (Siri, dictation, a meeting app's mic
    /// leg) must not earn a row in a panel of output sliders.
    var isPlayingOutput: Bool
}

enum ProcessCatalog {
    static let ignoredBundleIDs: Set<String> = [
        MixIdentity.appBundleID
    ]

    static func processes() -> [AudioProcess] {
        let ids: [AudioObjectID] = (try? HAL.getArray(AudioObjectID.system, kAudioHardwarePropertyProcessObjectList)) ?? []
        var live: Set<pid_t> = []
        let processes: [AudioProcess] = ids.compactMap { objectID in
            let pid: pid_t = (try? HAL.get(pid_t.self, objectID, kAudioProcessPropertyPID)) ?? 0
            guard pid > 0 else { return nil }
            live.insert(pid)
            let reported = (try? HAL.getCFString(objectID, kAudioProcessPropertyBundleID)) ?? ""
            let bundleID = owningBundleID(pid: pid) ?? reported
            guard !bundleID.isEmpty, !ignoredBundleIDs.contains(bundleID) else { return nil }
            let playing = HAL.flag(objectID, kAudioProcessPropertyIsRunningOutput)
            return AudioProcess(objectID: objectID, pid: pid, bundleID: bundleID, isPlayingOutput: playing)
        }
        ownerCache.prune(keeping: live)
        return processes
    }

    /// Grouped by owning application, so every renderer a browser spawns lands
    /// in one entry and a single route taps all of them.
    static func grouped() -> [String: [AudioProcess]] {
        Dictionary(grouping: processes(), by: \.bundleID)
    }

    static func displayName(bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    // MARK: - Owning application

    /// CoreAudio names the process that opened the audio device, and for a
    /// browser or an Electron app that is a renderer helper, not the app. Dia
    /// plays through `company.thebrowser.browser.helper.renderer`, so the row
    /// was titled "Browser Helper" and each helper claimed a row of its own,
    /// which also meant routing one of them left the rest on the old device.
    ///
    /// Resolving the owner fixes both: the row is named after the app, and the
    /// group holds every helper so one route taps all of them.
    ///
    /// Returns nil when the process does not live inside an application bundle
    /// at all, which is right for shared system services such as
    /// `com.apple.WebKit.GPU`: those belong to no single app, so the caller
    /// falls back to the identifier CoreAudio reported.
    private static func owningBundleID(pid: pid_t) -> String? {
        ownerCache.resolve(pid) { pid in
            guard let executable = executablePath(pid: pid),
                  let appURL = outermostAppBundle(containing: executable)
            else { return nil }
            return Bundle(url: appURL)?.bundleIdentifier
        }
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        let written = buffer.withUnsafeMutableBufferPointer { raw -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            return proc_pidpath(pid, base, UInt32(raw.count))
        }
        guard written > 0 else { return nil }
        let bytes = buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Helpers nest inside the application they belong to, as in
    /// `Dia.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper
    /// (Renderer).app/Contents/MacOS/Browser Helper (Renderer)`. Walking from
    /// the executable outward, the last bundle found is the application and
    /// every earlier one is a helper of it.
    private static func outermostAppBundle(containing path: String) -> URL? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var outermost: URL?
        while url.path != "/" {
            if url.pathExtension == "app" { outermost = url }
            url.deleteLastPathComponent()
        }
        return outermost
    }

    private static let ownerCache = OwnerCache()
}

/// Resolving a pid to its owning application costs a syscall and a bundle read,
/// and the process list is polled once a second, so answers are kept per pid.
/// Entries are dropped as soon as a pid leaves the audio process list, which
/// also stops a recycled pid from inheriting the previous owner's answer.
private final class OwnerCache: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [pid_t: String?]())

    /// A resolution that came back nil is cached too, so a process that belongs
    /// to no application is not re-walked every second.
    func resolve(_ pid: pid_t, _ work: (pid_t) -> String?) -> String? {
        if let cached = state.withLock({ $0[pid] }) { return cached }
        let resolved = work(pid)
        state.withLock { $0[pid] = resolved }
        return resolved
    }

    func prune(keeping live: Set<pid_t>) {
        state.withLock { cache in
            cache = cache.filter { live.contains($0.key) }
        }
    }
}
