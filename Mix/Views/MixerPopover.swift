import AppKit
import SwiftUI

// MARK: - Design tokens

/// The only type scale in Mix. DESIGN.md fixes it at 11 / 13 / 15, so every
/// size in the app comes from here and no view declares its own.
enum MixType {
    /// System output device name. DESIGN.md display/hero, 15/590.
    static let hero = Font.system(size: 15, weight: .semibold)
    /// App names and the input device name. DESIGN.md body, 13/510.
    static let body = Font.system(size: 13, weight: .medium)
    /// Destinations, the error line, the empty state, the Mix footer.
    /// DESIGN.md UI label, 11/510.
    static let label = Font.system(size: 11, weight: .medium)

    /// Icons sit on the same 11 / 13 / 15 scale as the text beside them.
    static let heroGlyph = Font.system(size: 15, weight: .medium)
    static let glyph = Font.system(size: 13, weight: .medium)
    static let smallGlyph = Font.system(size: 11, weight: .medium)

    /// Disclosure chevrons carry the row's weight one scale step below its text,
    /// so a 13 or 15 point row gets an 11 point chevron and an 11 point pill gets
    /// a 9. Two sizes, one rule, rather than the four the popover used to have.
    static let chevron = Font.system(size: 11, weight: .semibold)
    static let chevronSmall = Font.system(size: 9, weight: .semibold)

    /// The menu bar extra. Off the 11 / 13 / 15 scale on purpose: DESIGN.md
    /// specifies a 16 point icon in a 22 point extra.
    static let menuBarExtra = Font.system(size: 16, weight: .medium)
}

/// Every gap in the popover. DESIGN.md sets an 8 point base at compact density,
/// so these are the only spacing values and nothing writes a loose number.
enum MixSpace {
    /// DESIGN.md popover inset.
    static let popover: CGFloat = 10
    /// DESIGN.md row inset.
    static let row: CGFloat = 8
    /// DESIGN.md section gap.
    static let section: CGFloat = 8
    /// Half step, for the gap between a row and its own volume bar.
    static let tight: CGFloat = 4
    /// Glyph tile to the text beside it.
    static let gutter: CGFloat = 10
}

/// Fixed sizes the layout derives from, kept here so the volume bar indent and
/// the tile widths can never drift apart.
enum MixMetrics {
    static let popoverWidth: CGFloat = 320
    /// DESIGN.md radius scale: popover 20, row 12, glyph 8, app icon 7.
    static let popoverRadius: CGFloat = 20
    static let glyphRadius: CGFloat = 8
    static let appIconRadius: CGFloat = 7
    static let heroTile: CGFloat = 34
    static let appIcon: CGFloat = 28
    static let inputGlyph: CGFloat = 20
    static let heroSlider: CGFloat = 26
    static let rowSlider: CGFloat = 14
    static let inputSlider: CGFloat = 80
    /// The destination pill never takes more than this, so a long device name
    /// can never squeeze the app name it sits beside down to nothing.
    static let destinationMaxWidth: CGFloat = 140
    /// Volume bars start under the app name, not under its icon.
    static var nameIndent: CGFloat { appIcon + MixSpace.gutter }
}

enum MixPalette {
    static let fallback = Color(red: 1, green: 159 / 255, blue: 10 / 255)
    static let danger = Color(red: 1, green: 59 / 255, blue: 48 / 255)
    static let info = Color(red: 100 / 255, green: 210 / 255, blue: 1)
}

// MARK: - Popover

/// Direction B, "Weight Ladder". System controls and per-app controls are told
/// apart by scale and type weight alone, with no cards, boxes, or borders.
/// The output hero is the heaviest thing in the popover; the input line sits
/// directly beneath it as part of the same block; one hairline separates both
/// from a deliberately lighter app list.
struct MixerPopover: View {
    @EnvironmentObject private var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SystemOutputHero(
                device: snapshot.systemOutput,
                volume: snapshot.systemVolume,
                muted: snapshot.systemMuted,
                devices: snapshot.outputs,
                onSelect: { store.apply(.setDefaultOutput($0)) },
                onVolume: { store.apply(.setSystemVolume($0)) },
                onMute: { store.apply(.setSystemMuted($0)) }
            )

            SystemInputLine(
                device: snapshot.systemInput,
                volume: snapshot.systemInputVolume,
                devices: snapshot.inputs,
                onSelect: { store.apply(.setDefaultInput($0)) },
                onVolume: { store.apply(.setSystemInputVolume($0)) }
            )

            // The only separator in the design. Everything above it is the Mac,
            // everything below it is an app.
            Divider()
                .opacity(0.35)
                .padding(.vertical, MixSpace.section)

            if snapshot.apps.isEmpty {
                EmptyAppsRow()
            } else {
                ForEach(snapshot.apps) { app in
                    AppRouteRow(app: app, outputs: snapshot.outputs)
                        .disabled(store.showPermissionRepair)
                }
            }

            FooterBar()
        }
        .padding(MixSpace.popover)
        .frame(width: MixMetrics.popoverWidth)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: MixMetrics.popoverRadius, style: .continuous))
        .tint(Color(nsColor: .controlAccentColor))
    }

    private var snapshot: MixerSnapshot {
        store.snapshot
    }
}

// MARK: - System

/// The hero. Largest tile, heaviest name, tallest slider in the popover,
/// because this is the control reached for most often.
struct SystemOutputHero: View {
    var device: DeviceInfo
    var volume: Float
    var muted: Bool
    var devices: [DeviceInfo]
    var onSelect: (String) -> Void
    var onVolume: (Float) -> Void
    var onMute: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MixSpace.tight) {
            Menu {
                DestinationList(devices: devices) { uid in
                    if let uid { onSelect(uid) }
                }
            } label: {
                HStack(spacing: MixSpace.gutter) {
                    Image(systemName: "speaker.wave.2")
                        .font(MixType.heroGlyph)
                        .frame(width: MixMetrics.heroTile, height: MixMetrics.heroTile)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: MixMetrics.glyphRadius, style: .continuous))
                    DeviceName(device.name, font: MixType.hero)
                    Spacer(minLength: MixSpace.tight)
                    Image(systemName: "chevron.right")
                        .font(MixType.chevron)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: MixSpace.row) {
                Slider(value: Binding(
                    get: { Double(volume) },
                    set: { onVolume(Float($0)) }
                ), in: 0...1)
                .controlSize(.large)
                .frame(height: MixMetrics.heroSlider)
                .animation(.easeOut(duration: 0.1), value: volume)
                MuteButton(muted: muted) { onMute(!muted) }
            }
        }
        .padding(.horizontal, MixSpace.row)
    }
}

/// Subordinate by design: smaller glyph, secondary colour, and an inline slider
/// that takes only the right quarter of the width. No divider above it, so it
/// reads as part of the same system block as the hero.
struct SystemInputLine: View {
    var device: DeviceInfo
    var volume: Float?
    var devices: [DeviceInfo]
    var onSelect: (String) -> Void
    var onVolume: (Float) -> Void

    var body: some View {
        HStack(spacing: MixSpace.row) {
            Menu {
                DestinationList(devices: devices) { uid in
                    if let uid { onSelect(uid) }
                }
            } label: {
                HStack(spacing: MixSpace.row) {
                    Image(systemName: "mic")
                        .font(MixType.smallGlyph)
                        .frame(width: MixMetrics.inputGlyph)
                    DeviceName(device.name, font: MixType.body)
                    Image(systemName: "chevron.right")
                        .font(MixType.chevronSmall)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Takes its share of the row before the spacer does, so a long
            // device name shortens itself instead of shoving the slider away.
            .layoutPriority(1)

            Spacer(minLength: MixSpace.row)

            if let volume {
                Slider(value: Binding(
                    get: { Double(volume) },
                    set: { onVolume(Float($0)) }
                ), in: 0...1)
                .controlSize(.mini)
                .frame(width: MixMetrics.inputSlider, height: MixMetrics.rowSlider)
                .animation(.easeOut(duration: 0.1), value: volume)
            }
        }
        .padding(.horizontal, MixSpace.row)
        .padding(.top, MixSpace.tight)
    }
}

// MARK: - Apps

/// Lighter than the system block on purpose: secondary weight against the
/// hero's semibold, a thin slider, and an indent. Two lines, as approved.
/// Name and destination on top, volume beneath.
struct AppRouteRow: View {
    @EnvironmentObject private var store: MixerStore
    var app: AppRow
    var outputs: [DeviceInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: MixSpace.tight) {
            HStack(spacing: MixSpace.gutter) {
                Image(nsImage: store.icon(for: app.bundleID))
                    .resizable()
                    .frame(width: MixMetrics.appIcon, height: MixMetrics.appIcon)
                    .clipShape(RoundedRectangle(cornerRadius: MixMetrics.appIconRadius, style: .continuous))
                Text(app.name)
                    .font(MixType.body)
                    .lineLimit(1)
                    // The app name keeps its share of the row before the
                    // destination pill gets to grow.
                    .layoutPriority(1)
                Spacer(minLength: MixSpace.row)
                destinationMenu
            }

            HStack(spacing: MixSpace.row) {
                Slider(value: Binding(
                    get: { Double(app.volume) },
                    set: { store.apply(.setAppVolume(bundleID: app.bundleID, volume: Float($0))) }
                ), in: 0...1)
                .controlSize(.mini)
                .frame(height: MixMetrics.rowSlider)
                .animation(.easeOut(duration: 0.1), value: app.volume)
                MuteButton(muted: app.muted) {
                    store.apply(.setAppMuted(bundleID: app.bundleID, muted: !app.muted))
                }
            }
            .padding(.leading, MixMetrics.nameIndent)

            if let error = app.error {
                Text(error)
                    .font(MixType.label)
                    .foregroundStyle(MixPalette.info)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, MixMetrics.nameIndent)
            }
        }
        .padding(.horizontal, MixSpace.row)
        .padding(.vertical, MixSpace.tight)
        .contentShape(Rectangle())
    }

    /// An app following the system output says so. Naming the resolved device
    /// there read as if that device had been pinned deliberately, which is a
    /// different thing: a pinned app stays put when the system output changes.
    private var destinationLabel: String {
        app.outputUID == nil ? "System" : app.destinationName
    }

    /// The destination is a pill with its own visible chevron. The stock menu
    /// indicator is hidden only so this one can replace it, never to leave the
    /// control looking like plain text. Width is capped so a long device name
    /// truncates inside the pill instead of crowding out the app name.
    private var destinationMenu: some View {
        Menu {
            Button("System") {
                store.apply(.setAppOutput(bundleID: app.bundleID, uid: nil))
            }
            Divider()
            DestinationList(devices: outputs) { uid in
                store.apply(.setAppOutput(bundleID: app.bundleID, uid: uid))
            }
        } label: {
            HStack(spacing: MixSpace.tight) {
                Text(destinationLabel)
                    .font(MixType.label)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(MixType.chevronSmall)
                    .opacity(0.55)
            }
            .foregroundStyle(app.destinationIsFallback ? MixPalette.fallback : Color.primary)
            .padding(.horizontal, MixSpace.row)
            .padding(.vertical, MixSpace.tight)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .contentShape(Capsule())
            .transaction { $0.animation = nil }
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: MixMetrics.destinationMaxWidth, alignment: .trailing)
        .transaction { $0.animation = nil }
    }
}

/// Shown when nothing is playing. Mix never invents rows for apps that are not
/// running, because a slider here writes a real route for that bundle ID.
struct EmptyAppsRow: View {
    var body: some View {
        Text("No apps playing audio")
            .font(MixType.label)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MixSpace.row)
            .padding(.vertical, MixSpace.section)
    }
}

// MARK: - Shared controls

/// Device names are the only unbounded text in the popover. They tighten, then
/// shrink a little, then truncate, so an AirPods Pro Max with a long owner name
/// degrades gracefully instead of clipping at full size.
struct DeviceName: View {
    private let name: String
    private let font: Font

    init(_ name: String, font: Font) {
        self.name = name
        self.font = font
    }

    var body: some View {
        Text(name)
            .font(font)
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.85)
    }
}

/// Same glyph, same size, same position: the right end of every volume bar.
struct MuteButton: View {
    var muted: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(MixType.smallGlyph)
                .foregroundStyle(muted ? MixPalette.danger : .secondary)
                .frame(width: MixMetrics.inputGlyph, height: MixMetrics.inputGlyph)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.08), value: muted)
    }
}

struct DestinationList: View {
    var devices: [DeviceInfo]
    var onSelect: (String?) -> Void

    var body: some View {
        group("Built-in", .builtIn)
        group("Bluetooth", .bluetooth)
        group("USB", .usb)
        group("HDMI", .hdmi)
        leftoverGroup
    }

    private var leftover: [DeviceInfo] {
        devices.filter { device in
            switch device.transport {
            case .builtIn, .bluetooth, .usb, .hdmi, .airplay, .aggregate: return false
            case .other: return true
            }
        }
    }

    @ViewBuilder
    private var leftoverGroup: some View {
        if !leftover.isEmpty {
            Section("Other") {
                ForEach(leftover) { device in
                    Button(device.name) { onSelect(device.uid) }
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ transport: DeviceTransport) -> some View {
        let items = devices.filter { $0.transport == transport }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { device in
                    Button(device.name) { onSelect(device.uid) }
                }
            }
        }
    }
}

struct FooterBar: View {
    @EnvironmentObject private var store: MixerStore

    var body: some View {
        HStack {
            Menu {
                Toggle("Launch at Login", isOn: Binding(
                    get: { store.loginEnabled },
                    set: { _ in store.toggleLogin() }
                ))
                if let loginError = store.loginError {
                    Text("Launch at Login failed: \(loginError)")
                }
                Button("Repair Audio Permission") {
                    store.repairPermission()
                }
                .foregroundStyle(store.showPermissionRepair ? MixPalette.danger : .primary)
                Divider()
                Button("Quit Mix") {
                    store.quitMix()
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(MixType.glyph)
                    .foregroundStyle(.secondary)
                    .frame(width: MixMetrics.inputGlyph, height: MixMetrics.inputGlyph)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            Spacer()
            Text("Mix")
                .font(MixType.label)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, MixSpace.row)
        .padding(.top, MixSpace.section)
        .overlay(alignment: .top) {
            Divider().opacity(0.35)
        }
    }
}
