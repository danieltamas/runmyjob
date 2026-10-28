import Foundation

/// The Jobs tab's search and filter over every row of the last 30 days: the words of the query must all appear in the
/// row's repo, command, branch, worktree, commit, destination, state or id; the kind narrows by outcome or origin.
public struct JobRowFilter: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case all = "All", failed = "Failed", done = "Done", github = "GitHub", local = "Local" }

    public var query: String
    public var kind: Kind

    public init(query: String = "", kind: Kind = .all) {
        self.query = query
        self.kind = kind
    }

    public var isActive: Bool { kind != .all || !words.isEmpty }

    private var words: [String] {
        query.split(whereSeparator: \.isWhitespace).map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    }

    public func matches(_ row: JobRowPresentation) -> Bool {
        switch kind {
        case .all: break
        case .failed: guard row.state == .failed || row.state == .lost else { return false }
        case .done: guard row.state == .done else { return false }
        case .github: guard row.locationKind == .github else { return false }
        case .local: guard row.locationKind == .local else { return false }
        }
        let words = words
        guard !words.isEmpty else { return true }
        let haystack = [row.title, row.command, row.branch, row.worktree, row.commit, row.location.text, row.stateChip.text, row.id]
            .compactMap { $0 }.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return words.allSatisfy { haystack.contains($0) }
    }

    public func apply(_ sections: [(JobRowPresentation.Section, [JobRowPresentation])]) -> [(JobRowPresentation.Section, [JobRowPresentation])] {
        guard isActive else { return sections }
        return sections.compactMap { section, rows in
            let kept = rows.filter(matches)
            return kept.isEmpty ? nil : (section, kept)
        }
    }
}
