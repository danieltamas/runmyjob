import SwiftUI

/// The one frame every sheet uses: a title, a line on what it does, the content, and a footer where the way out is on the
/// left of the main action, both on the right edge. Fields inside are GlassField or SecretField, never the system look.
struct ModalFrame<Content: View>: View {
    let title: String
    var detail: String?
    var width: CGFloat = 520
    @ViewBuilder let content: Content
    var footer: ModalFooter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if let detail { Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            ScrollView { VStack(alignment: .leading, spacing: 14) { content }.frame(maxWidth: .infinity, alignment: .leading) }
                .scrollIndicators(.automatic)
            footer
        }
        .padding(22)
        .frame(width: width)
        .frame(minHeight: 200, maxHeight: 640)
        .background(Theme.canvas)
    }
}

/// `secondary` (Cancel, Done) then `primary`, right-aligned in one row; the primary is the filled pill.
struct ModalFooter: View {
    struct Action {
        let title: String
        var disabled = false
        let run: () -> Void
    }

    var secondary: Action?
    var primary: Action?

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            if let secondary { ActionButton(title: secondary.title, disabled: secondary.disabled, action: secondary.run) }
            if let primary { ActionButton(title: primary.title, style: .primary, disabled: primary.disabled, action: primary.run) }
        }
    }
}

/// A labelled field: the label above, the control below, the same gap everywhere.
struct FieldBlock<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            control
            if let detail { Text(detail).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// GlassField for a secret: the characters are never shown.
struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
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

/// A step's result line: the outcome in its colour, then what happened; the fix hint below it in the secondary colour.
struct StatusLine: View {
    let text: String
    var tone: JobRowTone = .plain
    var hint: String?

    enum JobRowTone { case ok, changed, failed, plain }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            if let hint { Text(hint).font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        }
    }

    private var color: Color {
        switch tone {
        case .ok: Theme.ok
        case .changed: Theme.teal
        case .failed: Theme.crit
        case .plain: Theme.textSecondary
        }
    }
}
