import SwiftUI
import SystemKit

/// The selected device sits above the list, with a chevron that opens it: cheap when one
/// emulator is running, explicit when there are more.
struct DevicePickerList: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            if let selected = model.androidSelectedDevice {
                selectedRow(selected)
                    .padding(10)
            }
            if expanded {
                Divider()
                VStack(spacing: 2) {
                    ForEach(model.androidDevices) { device in
                        candidateRow(device, selected: device.serial == model.androidSerial)
                    }
                }
                .padding(4)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(expanded ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor))
        )
    }

    private func selectedRow(_ device: AndroidDevice) -> some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                labels(device)
                Spacer(minLength: 8)
                DeviceChip(device: device, rooted: model.androidRooted)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(expanded ? Color.primary : Color.secondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("android.emulator.devicePicker"))
    }

    private func candidateRow(_ device: AndroidDevice, selected: Bool) -> some View {
        Button {
            model.androidSerial = device.serial
            expanded = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.7))
                    .font(.system(size: 14))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                labels(device)
                Spacer(minLength: 8)
                DeviceChip(device: device, rooted: selected && model.androidRooted)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func labels(_ device: AndroidDevice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.titleLine)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail(device))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func detail(_ device: AndroidDevice) -> String {
        let running = model.androidRunningSerials.contains(device.serial) || !device.isEmulator
        let state = L10n.string(running ? "android.emulator.running" : "android.emulator.stopped")
        return L10n.format("android.emulator.deviceDetail", device.subtitleLine, state)
    }
}

/// What kind of target this is, in words. It never claims an image: Android does not expose
/// "Google Play" per device, and a stopped AVD has no properties to read.
struct DeviceChip: View {
    let device: AndroidDevice
    let rooted: Bool

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(rooted ? Color.green : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((rooted ? Color.green : Color.primary).opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(rooted ? Color.green.opacity(0.4) : Color.secondary.opacity(0.3)))
            .fixedSize()
    }

    private var key: LocalizedStringKey {
        if rooted { return "android.emulator.rootedChip" }
        return device.isEmulator ? "android.emulator.emulatorChip" : "android.emulator.physicalChip"
    }
}
