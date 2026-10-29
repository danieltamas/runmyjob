import RMJCore
import SwiftUI

/// Adds a sink or edits one. The secret is typed here and goes to the Keychain; an empty secret on an edit keeps the stored one.
struct LogSinkSheet: View {
    let kind: LogSinkConfig.Kind
    let existing: LogSinkConfig?
    let done: () -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var site = "datadoghq.com"
    @State private var auth = LogSinkConfig.Auth.none
    @State private var user = ""
    @State private var secret = ""
    @State private var orgID = ""
    @State private var index = ""
    @State private var all = false
    @State private var tenants: Set<String> = []
    @State private var problem: String?
    private let knownTenants = Set((try? PanelLoader())?.rules()?.tenants.keys.map { $0 } ?? []).sorted()

    private var authChoices: [LogSinkConfig.Auth] {
        switch kind {
        case .loki: [.none, .basic, .bearer]
        case .datadog: [.apikey]
        case .elasticsearch: [.none, .basic, .apikey, .bearer]
        }
    }

    var body: some View {
        ModalFrame(title: existing == nil ? "Add \(LogStreamPane.title(kind))" : "Edit \(existing?.name ?? "")",
                   detail: "Output is redacted and cleaned of terminal escapes before it is written to the spool, then sent in the background.",
                   content: {
            FieldBlock(title: "Name") { GlassField(placeholder: "Team Loki", text: $name) }
            if kind == .datadog {
                FieldBlock(title: "Site", detail: "Where your Datadog account lives.") {
                    MenuField(title: site, options: LogSinkConfig.datadogSites) { site = $0 }
                }
            } else {
                FieldBlock(title: "URL", detail: "https, or http to this Mac or a tailnet address.") {
                    GlassField(placeholder: kind == .loki ? "https://loki.example.com" : "https://search.example.com:9200", text: $url, monospaced: true)
                }
            }
            if authChoices.count > 1 {
                FieldBlock(title: "Authentication") {
                    HStack(spacing: 6) {
                        ForEach(authChoices, id: \.self) { choice in SegmentChip(title: Self.label(choice), selected: auth == choice) { auth = choice } }
                    }
                }
            }
            if auth == .basic { FieldBlock(title: "User name") { GlassField(placeholder: "user", text: $user) } }
            if auth != .none {
                FieldBlock(title: Self.secretTitle(auth), detail: existing == nil ? "Stored in your Keychain, never in a file." : "Leave empty to keep the stored one.") {
                    SecretField(placeholder: existing == nil ? "" : "unchanged", text: $secret)
                }
            }
            if kind == .loki { FieldBlock(title: "Org ID (optional)", detail: "Sent as X-Scope-OrgID.") { GlassField(placeholder: "tenant-1", text: $orgID) } }
            if kind == .elasticsearch { FieldBlock(title: "Index (optional)", detail: "Defaults to rmj-logs.") { GlassField(placeholder: "rmj-logs", text: $index, monospaced: true) } }
            scope
            if let problem { ProblemText(text: problem) }
        }, footer: ModalFooter(secondary: .init(title: "Cancel", run: done), primary: .init(title: "Save", disabled: name.isEmpty, run: save)))
        .onAppear(perform: load)
    }

    private var scope: some View {
        FieldBlock(title: "Tenants this sink may receive", detail: "A run of any other tenant, or of none, never reaches it.") {
            VStack(alignment: .leading, spacing: 8) {
                SwitchRow(title: "All tenants and runs without one", isOn: $all)
                if !all {
                    if knownTenants.isEmpty { Text("Your rules file has no tenants yet.").font(.meta).foregroundStyle(Theme.textTertiary) }
                    HStack(spacing: 6) {
                        ForEach(knownTenants, id: \.self) { tenant in
                            SegmentChip(title: tenant, selected: tenants.contains(tenant)) {
                                if tenants.contains(tenant) { tenants.remove(tenant) } else { tenants.insert(tenant) }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func label(_ auth: LogSinkConfig.Auth) -> String {
        switch auth {
        case .none: "None"
        case .basic: "Basic"
        case .bearer: "Bearer token"
        case .apikey: "API key"
        }
    }

    private static func secretTitle(_ auth: LogSinkConfig.Auth) -> String {
        switch auth {
        case .basic: "Password"
        case .bearer: "Token"
        default: "API key"
        }
    }

    private func load() {
        guard let existing else { auth = authChoices[0]; return }
        name = existing.name; url = existing.url ?? ""; site = existing.site ?? "datadoghq.com"; auth = existing.auth
        user = existing.user ?? ""; orgID = existing.orgID ?? ""; index = existing.index ?? ""; all = existing.all; tenants = Set(existing.tenants)
    }

    private func save() {
        let home = RMJHome()
        var sink = LogSinkConfig(id: existing?.id ?? Self.makeID(name, taken: Set(LogSinkStore.load(home: home).sinks.map(\.id))), kind: kind,
                                 name: name.trimmingCharacters(in: .whitespaces), url: kind == .datadog ? nil : url.trimmingCharacters(in: .whitespaces),
                                 site: kind == .datadog ? site : nil, enabled: existing?.enabled ?? true, tenants: tenants.sorted(), all: all, auth: auth,
                                 user: auth == .basic ? user : nil, orgID: kind == .loki && !orgID.isEmpty ? orgID : nil,
                                 index: kind == .elasticsearch && !index.isEmpty ? index : nil)
        sink.tenants = all ? [] : sink.tenants
        do {
            try sink.validate()
            if auth != .none, !secret.isEmpty { try LogSinkAdmin.saveSecret(secret, for: sink, home: home) }
            else if auth != .none, existing == nil { throw LogSinkError(message: "enter the \(Self.secretTitle(auth).lowercased())") }
            var all = LogSinkStore.load(home: home).sinks
            if let at = all.firstIndex(where: { $0.id == sink.id }) { all[at] = sink } else { all.append(sink) }
            try LogSinkStore.save(all, home: home)
            done()
        } catch { problem = "\(error)" }
    }

    /// `team-loki`, then `team-loki-2` when the name is taken.
    static func makeID(_ name: String, taken: Set<String>) -> String {
        var base = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        base = base.split(separator: "-").joined(separator: "-")
        base = String((base.isEmpty ? "sink" : base).prefix(28))
        var candidate = base, number = 2
        while taken.contains(candidate) { candidate = "\(base)-\(number)"; number += 1 }
        return candidate
    }
}
