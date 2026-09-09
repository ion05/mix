import AppKit
import SwiftUI

struct MixerPopover: View {
    @EnvironmentObject private var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SystemDeviceSection(
                device: snapshot.systemOutput,
                volume: snapshot.systemVolume,
                muted: snapshot.systemMuted,
                devices: snapshot.outputs,
                symbol: "speaker.wave.2",
                titleSize: 15,
                titleWeight: .semibold,
                sliderHeight: 22,
                showsMute: true,
                onSelect: { store.apply(.setDefaultOutput($0)) },
                onVolume: { store.apply(.setSystemVolume($0)) },
                onMute: { store.apply(.setSystemMuted($0)) }
            )

            ForEach(displayedApps) { app in
                AppRouteRow(app: app, outputs: snapshot.outputs)
                    .disabled(store.showPermissionRepair)
            }

            SystemDeviceSection(
                device: snapshot.systemInput,
                volume: snapshot.systemInputVolume,
                muted: false,
                devices: snapshot.inputs,
                symbol: "mic",
                titleSize: 13,
                titleWeight: .medium,
                sliderHeight: 16,
                showsMute: false,
                onSelect: { store.apply(.setDefaultInput($0)) },
                onVolume: { store.apply(.setSystemInputVolume($0)) },
                onMute: { _ in }
            )

            FooterBar()
        }
        .padding(10)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .tint(Color(nsColor: .controlAccentColor))
    }

    private var snapshot: MixerSnapshot {
        store.snapshot ?? .shellPreview()
    }

    private var displayedApps: [AppRow] {
        snapshot.apps.isEmpty ? MixerSnapshot.shellPreview().apps : snapshot.apps
    }
}

struct SystemDeviceSection: View {
    var device: DeviceInfo
    var volume: Float?
    var muted: Bool
    var devices: [DeviceInfo]
    var symbol: String
    var titleSize: CGFloat
    var titleWeight: Font.Weight
    var sliderHeight: CGFloat
    var showsMute: Bool
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
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(device.name)
                        .font(.system(size: titleSize, weight: titleWeight))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let volume {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(volume) },
                        set: { onVolume(Float($0)) }
                    ), in: 0...1)
                    .controlSize(sliderHeight >= 22 ? .large : .small)
                    .frame(height: sliderHeight)
                    .animation(.easeOut(duration: 0.1), value: volume)
                    if showsMute {
                        Button {
                            onMute(!muted)
                        } label: {
                            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .foregroundStyle(muted ? MixPalette.danger : .secondary)
                        }
                        .buttonStyle(.plain)
                        .animation(.easeOut(duration: 0.08), value: muted)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 8)
    }
}

struct AppRouteRow: View {
    @EnvironmentObject private var store: MixerStore
    var app: AppRow
    var outputs: [DeviceInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(nsImage: store.icon(for: app.bundleID))
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                destinationMenu
            }
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { Double(app.volume) },
                    set: { store.apply(.setAppVolume(bundleID: app.bundleID, volume: Float($0))) }
                ), in: 0...1)
                .controlSize(.small)
                .frame(height: 16)
                .animation(.easeOut(duration: 0.1), value: app.volume)
                Button {
                    store.apply(.setAppMuted(bundleID: app.bundleID, muted: !app.muted))
                } label: {
                    Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .opacity(app.muted ? 1 : 0.85)
                        .foregroundStyle(app.muted ? MixPalette.danger : .secondary)
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.08), value: app.muted)
            }
            if let error = app.error {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MixPalette.info)
            }
        }
        .padding(8)
        .contentShape(Rectangle())
    }

    private var destinationMenu: some View {
        Menu {
            Button("System") {
                store.apply(.setAppOutput(bundleID: app.bundleID, uid: nil))
            }
            DestinationList(devices: outputs) { uid in
                store.apply(.setAppOutput(bundleID: app.bundleID, uid: uid))
            }
        } label: {
            HStack(spacing: 4) {
                if app.destinationIsBluetooth && !app.destinationIsFallback {
                    Circle()
                        .fill(MixPalette.connected)
                        .frame(width: 6, height: 6)
                }
                Text(app.destinationName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(app.destinationIsFallback ? MixPalette.fallback : Color.secondary)
                    .monospacedDigit()
                    .transaction { $0.animation = nil }
            }
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .transaction { $0.animation = nil }
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
                Button(store.loginEnabled ? "Launch at Login On" : "Launch at Login") {
                    store.toggleLogin()
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
            Spacer()
            Text("Mix")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Divider().opacity(0.35)
        }
    }
}
