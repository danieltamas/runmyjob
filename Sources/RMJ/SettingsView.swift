import SwiftUI

/// RMJ's settings window: every setting is edited in place and saved as it changes.
struct SettingsView: View {
    @ObservedObject var model: PanelModel
    /// See `PanelView`: the look is read through a static, so the root observes it for the whole tree.
    @ObservedObject private var appearance = Appearance.shared
    private var selection: SettingsPane {
        get { model.settingsPane }
        nonmutating set { model.settingsPane = newValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 0.5)
            ScrollView {
                pane.padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
            .id(selection)
            .transition(.opacity)
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(Backdrop())
        .preferredColorScheme(Theme.scheme)
        .animation(Motion.spring, value: selection)
        .id(appearance.look)
    }

    @ViewBuilder private var pane: some View {
        switch selection {
        case .general: GeneralPane()
        case .tailscale: TailscalePane(model: model)
        case .destinations: DestinationsPane(model: model)
        case .hooks: HooksPane()
        case .retention: RetentionPane()
        case .notifications: NotificationsPane()
        case .agent: AgentPane()
        case .more: MoreAppsPane()
        case .about: AboutPane()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: "Settings").padding(.horizontal, 10).padding(.bottom, 8)
            ForEach(SettingsPane.allCases) { pane in
                let selected = selection == pane
                Button {
                    withAnimation(Motion.spring) { selection = pane }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: pane.symbol)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(selected ? pane.color : Theme.textTertiary)
                            .frame(width: 24, height: 24)
                            .background(pane.color.opacity(selected ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(pane.rawValue).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.core)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98, lift: 0.08))
            }
            Spacer()
            AppControls().padding(.horizontal, 10)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 196)
        .background(Theme.canvas.opacity(0.55))
    }
}
