import AppKit
import SwiftUI

/// Direction B, "Weight Ladder". System controls and per-app controls are told
/// apart by scale and type weight alone, with no cards, boxes, or borders.
/// The output hero is the biggest, heaviest thing in the popover; the input line
/// sits directly beneath it as part of the same block; one hairline separates
/// both from a deliberately lighter app list.
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
                .padding(.vertical, 12)

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
        .padding(10)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .tint(Color(nsColor: .controlAccentColor))
    }

    private var snapshot: MixerSnapshot {
        store.snapshot
    }
}

// MARK: - System

/// The hero. Largest glyph, largest name, tallest slider in the popover, because
/// this is the control reached for most often.
struct SystemOutputHero: View {
    var device: DeviceInfo
    var volume: Float
    var muted: Bool
    var devices: [DeviceInfo]
    var onSelect: (String) -> Void
    var onVolume: (Float) -> Void
    var onMute: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                DestinationList(devices: devices) { uid in
                    if let uid { onSelect(uid) }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(device.name)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.3)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { Double(volume) },
                    set: { onVolume(Float($0)) }
                ), in: 0...1)
                .controlSize(.large)
                .frame(height: 26)
                .animation(.easeOut(duration: 0.1), value: volume)
                MuteButton(muted: muted) { onMute(!muted) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }
}

/// Subordinate by design: smaller glyph, lighter name, and an inline slider that
/// takes only the right third of the width. No divider above it, so it reads as
/// part of the same system block as the hero.
struct SystemInputLine: View {
    var device: DeviceInfo
    var volume: Float?
    var devices: [DeviceInfo]
    var onSelect: (String) -> Void
    var onVolume: (Float) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                DestinationList(devices: devices) { uid in
                    if let uid { onSelect(uid) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20)
                    Text(device.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()

            Spacer(minLength: 8)

            if let volume {
                Slider(value: Binding(
                    get: { Double(volume) },
                    set: { onVolume(Float($0)) }
                ), in: 0...1)
                .controlSize(.mini)
                .frame(width: 92, height: 14)
                .animation(.easeOut(duration: 0.1), value: volume)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

// MARK: - Apps

/// Lighter than the system block on purpose: regular weight name, thin slider.
/// Two lines, exactly as approved. Name and destination on top, volume beneath.
struct AppRouteRow: View {
    @EnvironmentObject private var store: MixerStore
    var app: AppRow
    var outputs: [DeviceInfo]

    /// Icon width plus its trailing gap, so the volume bar starts under the name.
    private let nameIndent: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: store.icon(for: app.bundleID))
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(app.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 8)
                destinationMenu
            }

            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { Double(app.volume) },
                    set: { store.apply(.setAppVolume(bundleID: app.bundleID, volume: Float($0))) }
                ), in: 0...1)
                .controlSize(.mini)
                .frame(height: 14)
                .animation(.easeOut(duration: 0.1), value: app.volume)
                MuteButton(muted: app.muted) {
                    store.apply(.setAppMuted(bundleID: app.bundleID, muted: !app.muted))
                }
            }
            .padding(.leading, nameIndent)

            if let error = app.error {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MixPalette.info)
                    .padding(.leading, nameIndent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    /// The destination is a pill with its own visible chevron. The stock menu
    /// indicator is hidden only so this one can replace it, never to leave the
    /// control looking like plain text.
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
            HStack(spacing: 5) {
                if app.destinationIsBluetooth && !app.destinationIsFallback {
                    Circle()
                        .fill(MixPalette.connected)
                        .frame(width: 6, height: 6)
                }
                Text(app.destinationName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundStyle(app.destinationIsFallback ? MixPalette.fallback : Color.primary)
            .padding(.leading, 8)
            .padding(.trailing, 7)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .contentShape(Capsule())
            .transaction { $0.animation = nil }
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .transaction { $0.animation = nil }
    }
}

/// Shown when nothing is playing. Mix never invents rows for apps that are not
/// running, because a slider here writes a real route for that bundle ID.
struct EmptyAppsRow: View {
    var body: some View {
        Text("No apps playing audio")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

// MARK: - Shared controls

/// Same glyph, same position, right end of every volume bar.
struct MuteButton: View {
    var muted: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(muted ? MixPalette.danger : .secondary)
                .frame(width: 20, height: 20)
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
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            Spacer()
            Text("Mix")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Divider().opacity(0.35)
        }
    }
}
