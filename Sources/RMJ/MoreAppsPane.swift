import AppKit
import RMJCore
import SwiftUI

/// The card accent for an app from the registry.
extension RegistryApp {
    @MainActor var hue: Color { Theme.hue(dark, light: light) }
}

/// The other tools from the same maker, read from the registry. RMJ needs none of them.
struct MoreAppsPane: View {
    @ObservedObject var model: MoreAppsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .more, title: "More apps",
                       detail: "Other open source tools from the maker of RMJ, for a Mac that runs coding agents. All MIT, all free.")
            checkRow
            group("In the menu bar", .menuBar)
            group("In the terminal", .terminal)
        }
        .onAppear { model.refresh(byPress: false) }
    }

    @ViewBuilder private var checkRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.checking {
                    ProgressView().controlSize(.small)
                    Text("Reading the latest app list...").font(.meta).foregroundStyle(Theme.textTertiary)
                } else if let read = model.readAt {
                    RelativeTime(date: read) { "Latest releases, checked \($0) ago." }.font(.meta).foregroundStyle(Theme.textTertiary)
                } else if let updated = model.registry?.updated {
                    RelativeTime(date: updated) { "Latest releases as of \($0) ago." }.font(.meta).foregroundStyle(Theme.textTertiary)
                } else {
                    Text("Latest releases.").font(.meta).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Read the app list again", size: 22) { model.refresh(byPress: true) }
            }
            if let leftOut = model.registry?.leftOut, leftOut > 0 {
                Text(leftOut == 1 ? "1 app needs a newer RMJ to show." : "\(leftOut) apps need a newer RMJ to show.")
                    .font(.meta).foregroundStyle(Theme.textTertiary)
            }
            if let problem = model.problem { ProblemText(text: problem) }
        }
    }

    @ViewBuilder private func group(_ title: String, _ kind: RegistryApp.Kind) -> some View {
        let members = model.apps.filter { $0.kind == kind }
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: title).padding(.leading, 4)
                ForEach(members) { app in
                    MoreAppCard(app: app, icon: model.icons[app.icon], installed: app.mac.flatMap { model.installed[$0.bundleID] })
                }
            }
        }
    }
}

private struct MoreAppCard: View {
    let app: RegistryApp
    let icon: NSImage?
    let installed: InstalledCopy?

    var body: some View {
        Bezel(glow: app.hue) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    MoreAppIcon(app: app, image: icon, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                                .lineLimit(1).fixedSize()
                            Chip(text: app.platform, color: app.hue)
                            Spacer(minLength: 8)
                            if let installed { LinkChip(title: "Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(installed.url) } }
                            if let site = app.site { LinkChip(title: "Website", url: site) }
                            LinkChip(title: "GitHub", url: app.repoURL)
                        }
                        Text(app.pitch).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        Text(app.detail).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        statusLine
                    }
                }
                // Full width, so a curl line reads whole. Only once there is a release: a command that fails is worse than none.
                if app.latest != nil { InstallLine(command: app.install) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The latest release and when it came out, and how the copy on this Mac compares with it.
    private var statusLine: some View {
        HStack(spacing: 6) {
            if let latest = app.latest {
                Chip(text: "v\(latest.version)", color: app.hue, style: .outline).help("The latest release on GitHub")
            } else {
                Chip(text: "In development", color: Theme.textTertiary, style: .dashed).help("No release on GitHub yet")
            }
            if let installed { installedChip(installed) }
            if let published = app.latest?.publishedAt {
                RelativeTime(date: published) { "Released \($0) ago" }.font(.meta).foregroundStyle(Theme.textTertiary)
            } else if installed == nil {
                Text("No release yet: watch the repository for the first one.").font(.meta).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func installedChip(_ installed: InstalledCopy) -> some View {
        if installed.version == nil, let source = installed.source {
            Chip(text: "Built from source", color: Theme.textSecondary, style: .outline).help("\(source): not a release, so RMJ makes no claim about updates.")
        } else if let version = installed.version {
            let bare = version.hasPrefix("v") ? String(version.dropFirst()) : version
            if let latest = app.latest?.version, ReleaseInfo.isNewer(latest, than: bare) {
                Chip(text: "Installed \(version), \(latest) is out", symbol: "arrow.down.circle", color: Theme.warn)
            } else if let latest = app.latest?.version, !ReleaseInfo.isNewer(bare, than: latest) {
                Chip(text: "Installed \(version), up to date", symbol: "checkmark", color: Theme.ok)
            } else {
                Chip(text: "Installed \(version)", color: Theme.textSecondary)
            }
        } else {
            Chip(text: "Installed, version unknown", color: Theme.textSecondary, style: .outline).help("Its Info.plist names no version RMJ could read.")
        }
    }
}

/// A small outlined link; the arrow says it leaves the app.
private struct LinkChip: View {
    let title: String
    var symbol = "arrow.up.right"
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    init(title: String, url: URL) {
        self.title = title
        help = url.absoluteString
        action = { NSWorkspace.shared.open(url) }
    }

    init(title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Chip(text: title, symbol: symbol, color: hovering ? Theme.textPrimary : Theme.textSecondary, style: .outline)
        }
        .buttonStyle(PressStyle(scale: 0.95, hit: AnyShape(Capsule()), lift: 0))
        .pointingHandCursor()
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help(help ?? title)
    }
}

/// The install command in a well, with a copy button that answers the press.
struct InstallLine: View {
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

/// The app's icon (fetched from the registry or bundled), or a glyph in its hue when there is none.
private struct MoreAppIcon: View {
    let app: RegistryApp
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        if let image {
            // A full-bleed mark is inset and rounded to sit beside the macOS-shaped ones.
            let fullBleed = app.iconShape == .fullBleed
            let inset = fullBleed ? size * 0.1 : 0
            let corner = (size - inset * 2) * 0.225
            Image(nsImage: image).resizable().interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: fullBleed ? corner : 0, style: .continuous))
                .padding(inset)
                .frame(width: size, height: size)
                .shadow(color: app.hue.opacity(0.35), radius: 10, y: 4)
        } else {
            GlyphDisc(symbol: app.kind == .menuBar ? "menubar.rectangle" : "terminal", color: app.hue, size: size)
        }
    }
}
