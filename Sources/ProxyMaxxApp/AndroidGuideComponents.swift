import SwiftUI
import SystemKit

/// Pieces the Android Emulator guide is built from. Layout only: each wraps state the app
/// already has. The one addition is tone, which is always carried by an icon or a word as
/// well as color.

/// One numbered card. The number is a brand-accent disc rather than an icon, because the
/// guide is a sequence: the number is information, not decoration.
///
/// `active: false` dims the card while a card above it is still unresolved. The content stays
/// readable and reachable; only its weight drops.
struct StepCard<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let active: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
        }
        .opacity(active ? 1 : 0.55)
        .allowsHitTesting(active)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .animation(.easeOut(duration: 0.15), value: active)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(active ? Color.accentColor : Color.secondary.opacity(0.45)))
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.format("android.emulator.stepLabel", number, L10n.string("\(title)"))))
    }
}

/// Three choices, one visible at a time. A segmented control is the platform's own answer
/// for "pick one of three", so the guide does not invent a card-radio pattern for it.
struct ModeSegments: View {
    @Binding var selection: AndroidInstallMode

    private static let choices: [AndroidInstallMode] = [.auto, .googleAPIs, .manual]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.choices) { mode in
                segment(mode)
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    private func segment(_ mode: AndroidInstallMode) -> some View {
        let chosen = selection == mode
        return Button {
            selection = mode
        } label: {
            Text(shortTitle(mode))
                .font(.callout.weight(chosen ? .semibold : .regular))
                .foregroundStyle(chosen ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    chosen ? Color(nsColor: .windowBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private func shortTitle(_ mode: AndroidInstallMode) -> LocalizedStringKey {
        switch mode {
        case .auto: return "android.mode.auto.short"
        case .googleAPIs: return "android.mode.googleAPIs.short"
        case .manual: return "android.mode.manual.short"
        case .revert: return "android.mode.revert.short"
        }
    }
}

/// One of the three Magisk facts, as its own surface. The heading carries the tone; the body
/// stays in body text color so the card is read, not scanned for color.
struct MagiskFact: View {
    enum Tone { case green, blue, orange }

    let tone: Tone
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    private var color: Color {
        switch tone {
        case .green: return .green
        case .blue: return .blue
        case .orange: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
            Text(detail)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .accessibilityElement(children: .combine)
    }
}

/// A labelled value the user may copy: the proxy address is typed into the emulator, so it
/// must not be something they have to retype from a screenshot.
struct ValueField: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
        .accessibilityElement(children: .combine)
    }
}

/// A statement about state, with an icon so it does not depend on color alone.
struct Notice: View {
    enum Tone { case warning, success, failure }

    let tone: Tone
    let text: String

    private var symbol: String {
        switch tone {
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .warning: return .orange
        case .success: return .green
        case .failure: return .red
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.35)))
    }
}

/// The install's segments, filled as the installer reports them: the count is the machine's
/// own progress, not ours.
struct SegmentedProgress: View {
    let total: Int
    let completed: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                Capsule()
                    .fill(index < completed ? Color.accentColor : Color.primary.opacity(0.1))
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The Install output: collapsed to a single row until Install or Revert is pressed, then
/// slides up to show the six steps and the installer's own lines.
///
/// The panel is opened by the action, not by a disclosure click, because the reason to look at
/// it is that a run just started. It stays open afterwards so the result can be read, and the
/// header closes it. The step marks are icon plus word, so state never depends on color.
struct InstallOutput: View {
    @EnvironmentObject var model: AppModel

    private var open: Bool { model.androidShowsOutput }

    var body: some View {
        VStack(spacing: 0) {
            header
            if open {
                panel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .animation(.easeOut(duration: 0.22), value: open)
    }

    private var header: some View {
        Button {
            model.androidShowsOutput.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
                Text("android.emulator.output")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                if model.androidBusy {
                    ProgressView().controlSize(.small)
                    Text(L10n.format(
                        "android.emulator.stepCounter",
                        model.androidProgress.completed,
                        model.androidProgress.total
                    ))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("android.emulator.output"))
        .accessibilityValue(Text(open ? "expanded" : "collapsed"))
    }

    private var panel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(1...AndroidInstallProgress.total, id: \.self) { step in
                        stepRow(step)
                    }
                    Divider().padding(.vertical, 4)
                    lines
                }
                .padding(.top, 10)
                .padding(.horizontal, 4)
            }
            .frame(height: 210)
            .onChange(of: model.androidLog.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var lines: some View {
        if model.androidLog.isEmpty {
            Text("android.emulator.output.waiting")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(model.androidLog.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(tone(for: line))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(index)
            }
        }
    }

    private func stepRow(_ step: Int) -> some View {
        let progress = model.androidProgress
        let done = progress.completed >= step
        let current = model.androidBusy && progress.completed + 1 == step
        return HStack(spacing: 8) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if current {
                    Image(systemName: "circle.inset.filled").foregroundStyle(.blue)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .accessibilityHidden(true)
            Text(L10n.string(AndroidInstallProgress.label(for: step)))
                .font(.callout.weight(current ? .semibold : .regular))
                .foregroundStyle(done || current ? .primary : .secondary)
            Spacer(minLength: 0)
        }
    }

    private func tone(for line: String) -> Color {
        if line.contains("❌") { return .red }
        if line.contains("⚠️") { return .orange }
        if line.contains("✅") { return .green }
        return .secondary
    }
}
