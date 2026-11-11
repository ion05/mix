// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Aayan Agarwal

import Foundation

/// Run by scripts/check.sh. Covers the ducking maths, the call-app filter and
/// when dictation pauses and resumes media.
@main
struct Checks {
    static func main() {
        // Ramp down: 0.75 of travel at 512/9600 per callback is 15 steps (14 reach 0.7467).
        var gain: Float = 1
        var steps = 0
        while gain != 0.25 {
            let next = TapRoute.rampStep(from: gain, to: 0.25, frames: 512, sampleRate: 48_000)
            precondition(next >= 0.25, "ramp undershot")
            precondition(next < gain, "ramp stalled")
            gain = next
            steps += 1
            precondition(steps <= 15, "ramp too slow")
        }
        precondition(steps == 15, "ramp down took \(steps) steps")

        var up: Float = 0.25
        while up != 1 { up = TapRoute.rampStep(from: up, to: 1, frames: 512, sampleRate: 48_000) }
        precondition(up == 1)

        precondition(TapRoute.rampStep(from: 1, to: 0.25, frames: 512, sampleRate: 0) == 0.25)

        precondition(abs(TapRoute.gain(volume: 0.6, muted: false, duck: 0.25) - 0.15) < 1e-6)
        precondition(TapRoute.gain(volume: 0.6, muted: true, duck: 0.25) == 0)
        precondition(TapRoute.gain(volume: 0.6, muted: false, duck: 1) == 0.6)

        let route = TapRoute(bundleID: "test", volume: 1, muted: false, outputUID: nil)
        precondition(!route.needsAudio)
        route.duckHold = true
        precondition(route.needsAudio)
        route.duckHold = false
        precondition(!route.needsAudio)

        precondition(MixIdentity.isCallApp("us.zoom.xos"))
        precondition(MixIdentity.isCallApp("com.apple.callservicesd"))
        precondition(!MixIdentity.isCallApp("com.spotify.client"))

        checkDictationPause()
    }

    static func checkDictationPause() {
        // The plain take: mic opens, music is playing, it pauses, mic closes,
        // and after the grace it plays again.
        var d = DictationPause()
        precondition(d.recordingChanged(true, enabled: true) == .checkPlaying(generation: 1))
        precondition(d.playingAnswer(true, generation: 1) == .pause)
        precondition(d.recordingChanged(false, enabled: true) == .scheduleResume(generation: 2))
        precondition(d.resumeDue(generation: 2) == .resume)
        precondition(!d.pausedByMix)

        // Nothing was playing: no pause, and so never a play afterwards.
        d = DictationPause()
        _ = d.recordingChanged(true, enabled: true)
        precondition(d.playingAnswer(false, generation: 1) == .none)
        precondition(d.recordingChanged(false, enabled: true) == .none)

        // A take shorter than the playing check pauses nothing.
        d = DictationPause()
        _ = d.recordingChanged(true, enabled: true)
        _ = d.recordingChanged(false, enabled: true)
        precondition(d.playingAnswer(true, generation: 1) == .none)
        precondition(!d.pausedByMix)

        // A second take inside the grace keeps the music paused and the stale
        // resume timer does nothing; the second take's end resumes it.
        d = DictationPause()
        _ = d.recordingChanged(true, enabled: true)
        _ = d.playingAnswer(true, generation: 1)
        _ = d.recordingChanged(false, enabled: true)
        precondition(d.recordingChanged(true, enabled: true) == .none)
        precondition(d.resumeDue(generation: 2) == .none)
        precondition(d.pausedByMix)
        precondition(d.recordingChanged(false, enabled: true) == .scheduleResume(generation: 4))
        precondition(d.resumeDue(generation: 4) == .resume)

        // Repeated reports of the same state change nothing.
        d = DictationPause()
        _ = d.recordingChanged(true, enabled: true)
        precondition(d.recordingChanged(true, enabled: true) == .none)
        precondition(d.generation == 1)

        // Turned off: no check, no pause.
        d = DictationPause()
        precondition(d.recordingChanged(true, enabled: false) == .none)
        precondition(d.recordingChanged(false, enabled: false) == .none)

        // Turned off mid-take: what Mix paused still comes back.
        d = DictationPause()
        _ = d.recordingChanged(true, enabled: true)
        _ = d.playingAnswer(true, generation: 1)
        precondition(d.recordingChanged(false, enabled: false) == .scheduleResume(generation: 2))
        precondition(d.resumeDue(generation: 2) == .resume)

        // Quitting mid-take resumes, and only once.
        d = DictationPause()
        _ = d.recordingChanged(true, enabled: true)
        _ = d.playingAnswer(true, generation: 1)
        precondition(d.shutdown() == .resume)
        precondition(d.shutdown() == .none)
        precondition(d.playingAnswer(true, generation: 1) == .none)

        // Quitting when Mix paused nothing presses nothing.
        d = DictationPause()
        precondition(d.shutdown() == .none)
    }
}
