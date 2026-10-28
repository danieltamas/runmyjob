import SwiftUI

/// The pane's title block: an eyebrow in the pane's colour, the title, one line on what it does.
struct PaneHeader: View {
    let pane: SettingsPane
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: pane.symbol).font(.system(size: 9, weight: .semibold))
                Eyebrow(text: pane.rawValue, color: pane.color)
            }
            .foregroundStyle(pane.color)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(pane.color.opacity(0.1), in: Capsule())
            Text(title).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// The grid every pane follows: rows keep a fixed height, the control sits on the right edge, and the pieces of a
/// control (field, unit, reset) have the same widths in every row, so their edges line up down the card.
enum SettingsMetrics {
    static let rowInset: CGFloat = 8
    static let rowHeight: CGFloat = 34
    static let fieldWidth: CGFloat = 84
    static let unitWidth: CGFloat = 168
    static let resetWidth: CGFloat = 52
}

/// A name on the left, its control on the right, on one baseline-centred line.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let detail { Text(detail).font(.meta).foregroundStyle(Theme.textTertiary) }
            }
            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: SettingsMetrics.rowHeight)
    }
}

/// A hairline between the rows of one card.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
}

/// One setting: its name and why it matters on the left of the card, the control below.
struct SettingsCard<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        Bezel {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    if let detail { Text(detail).font(.meta).foregroundStyle(Theme.textTertiary) }
                }
                VStack(alignment: .leading, spacing: 6) { content }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A choice among a few values, the chosen one lit.
struct SegmentChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(selected ? Theme.canvas : Theme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background {
                    if selected { Capsule().fill(Theme.brand) } else { Capsule().fill(Theme.wash.opacity(0.06)) }
                }
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(hit: AnyShape(Capsule()), lift: 0.08))
    }
}

/// A text field on a recessed core, lit at the edge while focused.
struct GlassField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
            .foregroundStyle(Theme.textPrimary)
            .focused($focused)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Theme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(focused ? Theme.teal.opacity(0.6) : Theme.hairline, lineWidth: focused ? 1 : 0.5)
            }
            .animation(Motion.snappy, value: focused)
    }
}

/// A multi-line editor in the same recessed style.
struct GlassEditor: View {
    @Binding var text: String
    var monospaced = false
    var minHeight: CGFloat = 90

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(Theme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// A pop-up menu in the same recessed style, its current choice as the title.
struct MenuField: View {
    let title: String
    let options: [String]
    let pick: (String) -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in Button(option) { pick(option) } }
        } label: {
            HStack {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Theme.canvas.opacity(hovering ? 0.9 : 0.7), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(hovering ? Theme.textTertiary : Theme.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointingHandCursor()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }
}

struct ProblemText: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .medium))
            Text(text).font(.meta).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.danger)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
