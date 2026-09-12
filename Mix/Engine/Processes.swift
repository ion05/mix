import Foundation
import CoreAudio
import AppKit

struct AudioProcess: Equatable {
    var objectID: AudioObjectID
    var pid: pid_t
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
        return ids.compactMap { objectID in
            let pid: pid_t = (try? HAL.get(pid_t.self, objectID, kAudioProcessPropertyPID)) ?? 0
            let bundleID = (try? HAL.getCFString(objectID, kAudioProcessPropertyBundleID)) ?? ""
            guard !bundleID.isEmpty, !ignoredBundleIDs.contains(bundleID) else { return nil }
            let playing = HAL.flag(objectID, kAudioProcessPropertyIsRunningOutput)
            return AudioProcess(objectID: objectID, pid: pid, bundleID: bundleID, isPlayingOutput: playing)
        }
    }

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
}
