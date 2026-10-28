import AppKit
import RMJCore
import SwiftUI

/// The menu bar panel: header, tab island, the open tab, footer (docs/DESIGN.md, The panel).
struct PanelView: View {
    static let width: CGFloat = 404
    /// Tall enough for a full tab, never taller than the screen can show under the menu bar.
    static var height: CGFloat { min(780, (NSScreen.main?.visibleFrame.height ?? 820) - 40) }
    @ObservedObject var model: PanelModel
    var height = PanelView.height
    @Namespace private var tabSpace
    @State private var panelVisible = true
    /// `Theme` reads the look through a static, which nothing observes: the root watches it and rebuilds the tree.
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            tabIsland
            ScrollView { content.padding(.horizontal, 14).padding(.bottom, model.tab == .routing ? 64 : 14) }
                .transaction(value: model.tab) { $0.animation = nil }
                .scrollIndicators(.hidden)
                .overlay(alignment: .bottomTrailing) {
                    if model.tab == .routing, model.snapshot.routing?.problem == nil, model.editingRule == nil {
                        FloatingPill(title: "New rule", symbol: "plus") { withAnimation(Motion.spring) { model.editingRule = -1 } }
                            .padding(.trailing, 14).padding(.bottom, 12)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            footer
        }
        .frame(width: Self.width, height: height)
        .background(Backdrop())
        .environment(\.colorScheme, Theme.scheme)
        .environment(\.panelVisible, panelVisible)
        .background(WindowVisibility(visible: $panelVisible))
        .onChange(of: panelVisible) { _, visible in
            model.panelVisible = visible
            if visible, model.tab == .jobs { model.select(.jobs) }
        }
        .background { SettingsOpener(model: model) }
        .id(appearance.look)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: .rmjTemplate).renderingMode(.template).resizable().frame(width: 20, height: 20).foregroundStyle(Theme.brand)
            Text("RMJ").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            let chip = model.snapshot.tailnetChip
            Chip(text: chip.text, symbol: chip.tone == .unknown ? "wifi.slash" : nil, color: Theme.color(chip.tone))
            Spacer(minLength: 8)
            if case .available(let release) = model.updateStatus {
                IconButton(symbol: "arrow.up.circle.fill", help: "RMJ \(release.version) is available") {
                    model.openSettings(.about)
                }
            }
            IconButton(symbol: "gearshape", help: "Open Settings") { model.openSettings(model.settingsPane) }
            if model.snapshot.runningCount > 0 {
                HStack(spacing: 5) {
                    PulseDot(color: Theme.running)
                    Text("\(model.snapshot.runningCount) running").font(.meta).foregroundStyle(Theme.running).lineLimit(1).fixedSize()
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }

    /// Every tab is a segment of the island. The open tab takes a wider share and shows its name; the others split the rest
    /// evenly, so the island is even whatever the number of tabs.
    private var tabIsland: some View {
        let tabs = Array(PanelTab.allCases)
        let open = 1.5
        return GeometryReader { proxy in
            let spacing: CGFloat = 2
            let free = proxy.size.width - spacing * CGFloat(tabs.count - 1)
            let unit = free / (CGFloat(tabs.count - 1) + open)
            HStack(spacing: spacing) {
                ForEach(tabs) { tab in
                    let active = model.tab == tab
                    Button { model.select(tab) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.symbol).font(.system(size: 13, weight: .medium))
                            if active { Text(tab.rawValue).font(.system(size: 12.5, weight: .semibold)).lineLimit(1) }
                            badge(tab, active: active)
                        }
                        .fixedSize()
                        .frame(width: active ? unit * open : unit, height: proxy.size.height)
                        .foregroundStyle(active ? Theme.teal : Theme.textSecondary)
                        .background {
                            if active {
                                Capsule().fill(Theme.teal.opacity(0.14))
                                    .overlay(CapsuleRing(width: 0.75).fill(Theme.teal.opacity(0.5), style: FillStyle(eoFill: true)))
                                    .shadow(color: Theme.teal.opacity(0.25), radius: 8)
                                    .matchedGeometryEffect(id: "active-tab", in: tabSpace)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle(scale: 0.97, hit: AnyShape(Capsule()), lift: 0.08))
                    .help(tab.rawValue)
                    .accessibilityLabel(tab.rawValue)
                }
            }
        }
        .frame(height: 34)
        // Only the island animates; the tab's content swaps at once instead of riding the spring.
        .animation(Motion.spring, value: model.tab)
        .padding(3)
        .background(Capsule().fill(Theme.core))
        .overlay(CapsuleRing(width: 0.5).fill(Theme.hairline, style: FillStyle(eoFill: true)).allowsHitTesting(false))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// A grey count capsule after the icon: live jobs, destinations, rules. Jobs adds a `crit` dot for an unseen failure.
    @ViewBuilder
    private func badge(_ tab: PanelTab, active: Bool) -> some View {
        let count: Int = switch tab {
        case .jobs: model.snapshot.runningCount + model.snapshot.queuedCount
        case .destinations: model.snapshot.destinations.count
        case .routing: model.snapshot.rulesState?.rules?.rules.count ?? 0
        }
        if count > 0 {
            Text("\(count)").font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(active ? Theme.teal.opacity(0.22) : Theme.wash.opacity(0.09), in: Capsule())
        }
        if tab == .jobs, model.snapshot.unseenFailure { Circle().fill(Theme.crit).frame(width: 6, height: 6) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .jobs: JobsTab(model: model)
        case .destinations: DestinationsTab(model: model)
        case .routing: RoutingTab(model: model)
        }
    }

    private var footer: some View {
        let footer = model.snapshot.footer
        return HStack {
            if let notice = model.notice {
                Text(notice).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else {
            HStack(spacing: 10) {
                ForEach(footer.polls, id: \.self) { Text($0).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                    .help("GitHub is polled every 15 s while a job is queued or running and every 120 s (300 s for quiet repos) otherwise; boxes every 30 s")
                if let budget = footer.rateBudget { Text(budget).font(.meta).foregroundStyle(Theme.warn).lineLimit(1) }
            }
            }
            Spacer(minLength: 8)
            AppControls()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}

/// `showSettingsWindow:` does nothing from a menu bar item on macOS 14 and later; the `openSettings` action does.
private struct SettingsOpener: View {
    let model: PanelModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onAppear { model.showSettingsWindow = { openSettings() } }
    }
}
