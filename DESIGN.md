# Design System — Mix

## Product Context

- **What this is:** Native macOS 26 menu-bar extra for dual-device per-app output (call on one device, music on another).
- **Who it's for:** You, daily Zoom/Spotify split.
- **Space/industry:** Mac audio extras. Peers: Control Center Sound (clone), SoundSource (anti-reference), teenysound (closer peer).
- **Project type:** native macOS menu-bar utility.

## Aesthetic Direction

- **Direction:** Native Tahoe Control Center module
- **Decoration level:** minimal (specular glass only)
- **Mood:** It was always part of macOS. The only Mix identity on screen is the 11pt footer word.
- **Reference:** macOS Control Center Sound module

## Typography

- **Display/Hero:** SF Pro Text 15/590 — current system output name
- **Body:** SF Pro Text 13/510 — app names, input device name
- **UI/Labels:** SF Pro Text 11/510 — destinations and Mix footer
- **Data/Tables:** SF Pro Text with `monospacedDigit` / tabular nums on 0–100
- **Code:** n/a
- **Loading:** system only (`.font(.system(...))`). No webfonts.
- **Scale:** 11 / 13 / 15. Extra icon ~16pt in a 22pt extra.

## Color

- **Approach:** restrained. No Mix brand hex.
- **Primary:** user’s macOS accent (`NSColor.controlAccentColor` / SwiftUI `.tint`). Example `#007AFF`.
- **Secondary:** semantic system labels and fills
- **Neutrals:** system materials (Liquid Glass / ultraThinMaterial)
- **Semantic:** connected `#34C759`, fallback `#FF9F0A`, mute/TCC `#FF3B30`, info `#64D2FF`
- **Dark mode:** system materials. Do not invent a Mix dark palette.

## Spacing

- **Base unit:** 8px
- **Density:** compact
- **Scale:** popover width 320, corner radius 20, row inset 8–10, section gap 8

## Layout

- **Approach:** grid-disciplined vertical stack
- **Grid:** one column, 320pt max
- **Max content width:** 320
- **Border radius:** popover 20, row 12, glyph 8, app icon 7

## Motion

- **Approach:** minimal-functional
- **Easing:** system extra present/dismiss
- **Duration:** slider thumb ~100ms glass; mute 80ms opacity; device snap-back 0ms (no bounce)

## Do

- SwiftUI `MenuBarExtra` `.window` style
- Xcode 26 standard controls so Liquid Glass is automatic
- Destination picker is a Control Center–style submenu (Built-in, Bluetooth, USB, HDMI)
- Template `speaker.wave.2` extra; slashed variant when system output is muted

## Do not

- AppKit-drawn custom chrome
- Inter, Satoshi, or any custom typeface
- Mix hex, purple, extra windows, pin button, per-app menu-bar icons
- AirPlay in the per-app destination list
- Webfonts

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-09-08 | Initial design system | /design-consultation: Control Center clone, footer Mix only |
