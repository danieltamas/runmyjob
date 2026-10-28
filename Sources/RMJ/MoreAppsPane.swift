import AppKit
import RMJCore
import SwiftUI

/// One of the maker's other open source tools, as the More apps pane shows it.
private struct MoreApp: Identifiable {
    enum Kind { case menuBar, terminal }

    let name: String
    /// The file in Support/MoreApps, copied into the bundle by scripts/bundle.sh.
    let icon: String
    /// The icon fills its square, so it is inset and rounded to sit beside the macOS-shaped ones.
    var fullBleed = false
    let kind: Kind
    let platform: String
    let pitch: String
    let detail: String
    let install: String
    let repo: URL
    var site: URL?
    /// Set for macOS apps, so one already on this Mac says "Installed".
    var bundleID: String?
    let dark: UInt32
    let light: UInt32

    var id: String { name }
    @MainActor var hue: Color { Theme.hue(dark, light: light) }
    /// `owner/name` for the releases lookup.
    var slug: String { repo.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var installedURL: URL? { bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }
    var isInstalled: Bool { installedURL != nil }
    var installedVersion: String? {
        installedURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
    }

    static let all: [MoreApp] = [
        MoreApp(name: "Bton", icon: "bton", kind: .menuBar, platform: "macOS",
                pitch: "Pull requests that move themselves.",
                detail: "Runs your team's review flow with coding agents, Claude Code, Codex or any CLI, from the menu bar.",
                install: "brew install --cask danieltamas/tap/bton",
                repo: URL(string: "https://github.com/danieltamas/bton")!, bundleID: "ro.danieltamas.bton", dark: 0x5EE6E0, light: 0x0B7F86),
        MoreApp(name: "MacMax", icon: "macmax", kind: .menuBar, platform: "macOS",
                pitch: "Why is my Mac slow? One answer.",
                detail: "Shows what is using your Mac, checks it on a schedule and says what to close, what to clean and whether your VPN is on.",
                install: "brew install --cask danieltamas/tap/macmax",
                repo: URL(string: "https://github.com/danieltamas/macmax")!, bundleID: "ro.danieltamas.macmax", dark: 0xFFB454, light: 0xB45309),
        MoreApp(name: "Axon", icon: "axon", kind: .terminal, platform: "macOS and Linux",
                pitch: "Your coding agents, on one bus.",
                detail: "Lets Claude Code, Codex, OpenCode and Hermes see and talk to each other, and shows what each one does and costs. Fully local.",
                install: "brew install danieltamas/tap/axon",
                repo: URL(string: "https://github.com/danieltamas/axon")!, dark: 0x4ADE80, light: 0x15803D),
        MoreApp(name: "Run.dev", icon: "rundev", fullBleed: true, kind: .terminal, platform: "macOS and Linux",
                pitch: "Every local service, one dashboard.",
                detail: "One binary starts and watches the services of all your projects from a terminal dashboard, with no config files to babysit.",
                install: "curl -fsSL https://getrun.dev/install.sh | bash",
                repo: URL(string: "https://github.com/danieltamas/run.dev")!, site: URL(string: "https://getrun.dev")!,
                dark: 0x45C8D4, light: 0x0A7C93),
        MoreApp(name: "Cloak", icon: "cloak", fullBleed: true, kind: .terminal, platform: "CLI and VS Code",
                pitch: "Keep .env secrets away from AI agents.",
                detail: "Agents see sandbox values, you see the real ones, and your app still runs with real credentials. Encrypted vault, Touch ID.",
                install: "curl -fsSL https://getcloak.dev/install.sh | sh",
                repo: URL(string: "https://github.com/danieltamas/cloak")!, site: URL(string: "https://getcloak.dev")!,
                dark: 0x5B9BFF, light: 0x2457C5),
    ]
}

/// The latest release of each app, asked of GitHub when the pane opens and kept for an hour: the page never says
/// "in development" or shows a version that a release has overtaken.
@MainActor private final class ReleaseModel: ObservableObject {
    @Published var outcomes: [String: ReleaseFeed.Outcome] = [:]
    private static var cache: [String: (Date, ReleaseFeed.Outcome)] = [:]

    func load() async {
        await withTaskGroup(of: (String, ReleaseFeed.Outcome).self) { group in
            for app in MoreApp.all {
                if let hit = Self.cache[app.slug], Date().timeIntervalSince(hit.0) < 3_600 { outcomes[app.id] = hit.1; continue }
                group.addTask { (app.id, await ReleaseFeed.latest(repo: app.slug)) }
            }
            for await (id, outcome) in group {
                outcomes[id] = outcome
                if let app = MoreApp.all.first(where: { $0.id == id }), outcome != .unavailable { Self.cache[app.slug] = (Date(), outcome) }
            }
        }
    }
}

/// The other tools from the same maker. RMJ needs none of them.
struct MoreAppsPane: View {
    @StateObject private var releases = ReleaseModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .more, title: "More apps",
                       detail: "Other open source tools from the maker of RMJ, for a Mac that runs coding agents. All MIT, all free.")
            group("In the menu bar", .menuBar)
            group("In the terminal", .terminal)
        }
        .task { await releases.load() }
    }

    private func group(_ title: String, _ kind: MoreApp.Kind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title).padding(.leading, 4)
            ForEach(MoreApp.all.filter { $0.kind == kind }) { MoreAppCard(app: $0, release: releases.outcomes[$0.id]) }
        }
    }
}

private struct MoreAppCard: View {
    let app: MoreApp
    let release: ReleaseFeed.Outcome?

    var body: some View {
        Bezel(glow: app.hue) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    MoreAppIcon(app: app, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Chip(text: app.platform, color: app.hue)
                            statusChips
                            Spacer(minLength: 8)
                            if let site = app.site { LinkChip(title: "Website", url: site) }
                            LinkChip(title: "GitHub", url: app.repo)
                        }
                        Text(app.pitch).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        Text(app.detail).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Full width, so a curl line reads whole instead of cut in the middle.
                if release == .noRelease {
                    Text("No release yet: watch the repository for the first one.").font(.meta).foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 66)
                } else {
                    InstallLine(command: app.install)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension MoreAppCard {
    /// The version RMJ found on GitHub, set against the one on this Mac when the app is installed.
    @ViewBuilder fileprivate var statusChips: some View {
        let installed = app.installedVersion
        switch release {
        case .release(let info):
            if let installed, ReleaseInfo.isNewer(info.version, than: installed) {
                Chip(text: "Installed \(installed)", color: Theme.ok)
                Chip(text: "Update \(info.version)", symbol: "arrow.up.circle", color: Theme.warn)
            } else if let installed {
                Chip(text: "Installed \(installed), up to date", color: Theme.ok)
            } else {
                Chip(text: "v\(info.version)", color: Theme.textSecondary, style: .outline)
            }
        case .noRelease:
            Chip(text: "In development", color: Theme.textTertiary, style: .dashed)
        case .unavailable, nil:
            if let installed { Chip(text: "Installed \(installed)", color: Theme.ok) } else if app.isInstalled { Chip(text: "Installed", color: Theme.ok) }
        }
    }
}

/// A small outlined link that opens in the browser; the arrow says it leaves the app.
private struct LinkChip: View {
    let title: String
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Chip(text: title, symbol: "arrow.up.right", color: hovering ? Theme.textPrimary : Theme.textSecondary, style: .outline)
        }
        .buttonStyle(PressStyle(scale: 0.95, hit: AnyShape(Capsule()), lift: 0))
        .pointingHandCursor()
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help(url.absoluteString)
    }
}

/// The install command in a well, with a copy button that answers the press.
private struct InstallLine: View {
    let command: String

    var body: some View {
        HStack(spacing: 6) {
            Text("$").font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            Text(command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 6)
            CopyButton(text: command, help: "Copy the install command")
        }
        .padding(.leading, 10).padding(.trailing, 3).padding(.vertical, 3)
        .background(Theme.wash.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Copies its text, shows a check for a moment, and a second press restarts that moment.
private struct CopyButton: View {
    let text: String
    let help: String
    @State private var copied = false
    /// The pending reset, cancelled by a new press so the check always stays the full time.
    @State private var reset: Task<Void, Never>?

    var body: some View {
        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : help,
                   tint: copied ? Theme.ok : Theme.textSecondary, size: 22) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(Motion.snappy) { copied = true }
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(Motion.snappy) { copied = false }
            }
        }
    }
}

/// The app's own icon from the bundle, or a glyph in its hue when the bundle has none (a build run from the scratch path).
private struct MoreAppIcon: View {
    let app: MoreApp
    let size: CGFloat

    /// Read once per icon: the lookup reads the disk and must not run on every redraw.
    @MainActor private static var cache: [String: NSImage?] = [:]

    var body: some View {
        if let image = Self.image(app.icon) {
            let inset = app.fullBleed ? size * 0.1 : 0
            let corner = (size - inset * 2) * 0.225
            Image(nsImage: image).resizable().interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: app.fullBleed ? corner : 0, style: .continuous))
                .padding(inset)
                .frame(width: size, height: size)
                .shadow(color: app.hue.opacity(0.35), radius: 10, y: 4)
        } else {
            GlyphDisc(symbol: app.kind == .menuBar ? "menubar.rectangle" : "terminal", color: app.hue, size: size)
        }
    }

    @MainActor private static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let image = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "MoreApps").flatMap(NSImage.init(contentsOf:))
        cache[name] = .some(image)
        return image
    }
}
