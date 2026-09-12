# Contributing to Mix

Thanks for looking. Mix is small and the bar for a useful contribution is low.

## Getting set up

You need macOS 26 and Xcode 26. Clone, open `Mix.xcodeproj`, set Team to your
own Apple ID under Signing & Capabilities, and change the bundle identifier to
something under a domain you control. Build and run, and Mix appears in the
menu bar.

The first time Mix taps an app, macOS asks for System Audio Recording. Grant it
or nothing will route.

## Where things live

```
Mix/MixApp.swift              MenuBarExtra, scroll handling, quit lifecycle
Mix/MixerStore.swift          main-actor state the popover binds to
Mix/Models.swift              snapshot and command types, design-free
Mix/Views/MixerPopover.swift  the entire UI, plus the design tokens
Mix/Engine/AudioEngine.swift  owns every tap; runs on one serial queue
Mix/Engine/TapRoute.swift     a single app's tap and aggregate device
Mix/Engine/Devices.swift      CoreAudio device enumeration and volume
Mix/Engine/Processes.swift    audio processes, resolved to their owning app
Mix/Engine/HAL.swift          typed CoreAudio property access
Mix/Engine/Persistence.swift  saved routes on disk
```

Everything runs in one process. There is no helper, no daemon, and no XPC.
`AudioEngine` confines all its mutable state to a single serial queue and
`MixerStore` is `@MainActor`, so the boundary between them is the only place
concurrency matters.

## House rules

**Read `DESIGN.md` before any visual change.** It fixes the type scale at
11 / 13 / 15, the spacing base at 8, and the semantic colours. It is not a
suggestion. If a change needs to deviate, say so in the pull request and explain
why.

**No loose numbers in views.** Every size, gap, and radius comes from `MixType`,
`MixSpace`, `MixMetrics` or `MixPalette` at the top of `MixerPopover.swift`. If
you need a value that is not there, add it to the token with a comment saying
what it is for.

**Read CoreAudio properties through `HAL`.** Call `HAL.get` with the type spelled
out, `HAL.flag` for boolean properties, `HAL.getArray` for lists. Do not call
`AudioObjectGetPropertyData` directly. There is a comment in `HAL.swift`
explaining the type-inference trap this exists to prevent; it is worth reading
before you decide the wrapper is unnecessary ceremony.

**Never invent UI state.** The popover shows what is actually happening. No
placeholder rows, no example apps, no fabricated devices. A slider in this app
writes a real audio route, so a fake row is a real bug.

**Match the surrounding code.** Comments explain why, not what. Keep them where
the reasoning is not obvious from the code.

## Pull requests

Say what changed and why. If it is a bug fix, describe the failure: what you
did, what happened, what should have happened. If it touches audio routing, say
which apps you tested with, because native apps, Chromium apps, and Electron
apps all behave differently.

Keep commits focused. One logical change per commit is easier to review and
easier to revert.

There is no CI yet, so build and run before you open a pull request.

## Good first issues

The limitations in `README.md` are the honest backlog:

- **A test target.** There is none. Even a few tests around `Processes.swift`
  owner resolution and `Devices.swift` classification would help.
- **An app icon.** The asset catalogue has empty slots waiting.
- **Browser renderer churn.** Chromium spawns and kills renderers as tabs open
  and close, which rebuilds the route and can glitch audio. Narrowing the tapped
  set is the likely fix.
- **AirPlay.** Currently excluded because the aggregate device cannot be clocked
  against an AirPlay output. If you know a way around this, it would be a real
  improvement.

## Licence

Mix is GPL-3.0-or-later. By contributing you agree your work ships under the
same terms. New source files need the SPDX header the existing files carry:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
```
