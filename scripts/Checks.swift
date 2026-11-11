// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Aayan Agarwal

import Foundation

/// Run by scripts/check.sh. Covers the ducking maths and the call-app filter.
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

        // Device mute: a hold-only route needs audio but earns no row, and a
        // route on a muted device is silent whatever its own volume says.
        route.muteHold = true
        precondition(route.needsAudio && route.isMuteHoldOnly)
        route.setVolume(0.5)
        precondition(!route.isMuteHoldOnly)
        route.muteHold = false
        route.setVolume(1)
        precondition(!route.needsAudio)

        // routes.json from before per-device mute still loads, routes intact.
        let legacy = #"{"apps":{"com.spotify.client":{"volume":0.5,"muted":false}},"didRequestAudioPermission":true}"#
        let decoded = try! JSONDecoder().decode(SavedStore.self, from: Data(legacy.utf8))
        precondition(decoded.apps["com.spotify.client"]?.volume == 0.5)
        precondition(decoded.didRequestAudioPermission && decoded.mutedOutputUIDs.isEmpty)
        var muted = SavedStore.empty
        muted.mutedOutputUIDs = ["BuiltInSpeakerDevice"]
        let roundTrip = try! JSONDecoder().decode(SavedStore.self, from: JSONEncoder().encode(muted))
        precondition(roundTrip == muted)

        precondition(MixIdentity.isCallApp("us.zoom.xos"))
        precondition(MixIdentity.isCallApp("com.apple.callservicesd"))
        precondition(!MixIdentity.isCallApp("com.spotify.client"))
    }
}
