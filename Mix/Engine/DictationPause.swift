// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Aayan Agarwal

import Foundation
import Darwin
import os

/// Decides when dictation pauses media and when it plays it again. Pure state,
/// no IO, so `scripts/Checks.swift` can drive it through every ordering.
///
/// "Dictating" means some app other than a call app is recording from a
/// microphone, which is exactly when macOS shows the orange mic dot. That
/// covers Willow, Claude's dictation, Apple's own dictation and anything
/// similar without Mix having to know their names.
///
/// The one rule that matters: Mix only ever sends play to undo a pause it sent
/// itself. Media the user had already paused is never started.
struct DictationPause: Equatable {
    enum Effect: Equatable {
        case none
        /// Ask whether anything is playing. The answer comes back through
        /// `playingAnswer(_:generation:)` carrying the same generation.
        case checkPlaying(generation: Int)
        case pause
        /// Come back through `resumeDue(generation:)` after a short grace, so a
        /// dictation app that drops the mic for a moment does not bounce the
        /// music back on between two takes.
        case scheduleResume(generation: Int)
        case resume
    }

    private(set) var recording = false
    private(set) var pausedByMix = false
    /// Bumped on every start and stop, so a late playing-check answer or a
    /// stale resume timer can tell it no longer applies.
    private(set) var generation = 0

    mutating func recordingChanged(_ isRecording: Bool, enabled: Bool) -> Effect {
        guard isRecording != recording else { return .none }
        recording = isRecording
        generation += 1
        if isRecording {
            // Restarted inside the resume grace: the media is still paused
            // from the last take, so there is nothing to check.
            guard !pausedByMix, enabled else { return .none }
            return .checkPlaying(generation: generation)
        }
        return pausedByMix ? .scheduleResume(generation: generation) : .none
    }

    /// The answer to `.checkPlaying`. A dictation shorter than the check
    /// pauses nothing, because the generation has moved on by then.
    mutating func playingAnswer(_ isPlaying: Bool, generation answered: Int) -> Effect {
        guard answered == generation, recording, isPlaying, !pausedByMix else { return .none }
        pausedByMix = true
        return .pause
    }

    mutating func resumeDue(generation due: Int) -> Effect {
        guard due == generation, !recording, pausedByMix else { return .none }
        pausedByMix = false
        return .resume
    }

    /// Mix is quitting. Media it paused must not stay paused because of it.
    mutating func shutdown() -> Effect {
        generation += 1
        guard pausedByMix else { return .none }
        pausedByMix = false
        return .resume
    }
}

/// Pauses and resumes whatever macOS considers Now Playing, the same target
/// the keyboard's play/pause key reaches: Spotify, Music, a video in a browser.
///
/// MediaRemote is private, and since macOS 15.4 it answers state questions
/// only for Apple-signed processes. Asked from Mix, "is anything playing?"
/// always says no. Commands are still accepted, so `send` calls it in-process,
/// while `isPlaying` asks through `/usr/bin/osascript`, which Apple signs.
///
/// CoreAudio's "process is running output" is not a substitute. Music and
/// several browsers keep their output stream open while paused, so trusting it
/// would make Mix press play on media the user had paused themselves.
enum NowPlaying {
    enum Command: UInt32 {
        case play = 0   // kMRPlay
        case pause = 1  // kMRPause
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let log = Logger(subsystem: MixIdentity.appBundleID, category: "dictation")
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MediaRemote.framework"
    /// Long enough for a cold osascript launch, short enough that a hung one
    /// cannot leave a dictation waiting on it.
    private static let checkTimeout: TimeInterval = 2

    private static let sendCommand: SendCommand? = {
        guard let handle = dlopen(frameworkPath + "/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    /// Explicit play or pause, never a toggle, so a wrong guess about state
    /// can at worst do nothing rather than start something.
    static func send(_ command: Command) {
        guard let sendCommand else {
            log.error("MediaRemote unavailable; cannot send \(String(describing: command), privacy: .public)")
            return
        }
        if !sendCommand(command.rawValue, nil) {
            log.error("MediaRemote rejected \(String(describing: command), privacy: .public)")
        }
    }

    /// Answers on a background queue. Any failure answers false, because a
    /// false "not playing" only means one pause is missed, while a false
    /// "playing" would later start music the user had stopped.
    static func isPlaying(_ completion: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(queryIsPlaying())
        }
    }

    private static let script = """
        ObjC.import('Foundation');
        var bundle = $.NSBundle.bundleWithPath('\(frameworkPath)/');
        bundle.load;
        var request = $.NSClassFromString('MRNowPlayingRequest');
        request ? String(request.localIsPlaying) : 'false';
        """

    private static func queryIsPlaying() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            log.error("osascript failed to launch: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard exited.wait(timeout: .now() + checkTimeout) == .success else {
            process.terminate()
            log.error("osascript timed out asking what is playing")
            return false
        }
        guard process.terminationStatus == 0 else {
            log.error("osascript exited \(process.terminationStatus) asking what is playing")
            return false
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let answer = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return answer == "true"
    }
}
