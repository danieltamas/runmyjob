import RMJCore

/// Rows drawn a page at a time: hundreds of expanded rows at once make the panel stall when a tab opens.
enum RowPaging {
    static let pageSize = 25

    /// The first `limit` settled rows across the sections, each section keeping its own heading; running and queued
    /// rows are always all there.
    static func page(_ sections: [(JobRowPresentation.Section, [JobRowPresentation])], limit: Int) -> [(JobRowPresentation.Section, [JobRowPresentation])] {
        var left = limit
        var out: [(JobRowPresentation.Section, [JobRowPresentation])] = []
        for (section, rows) in sections {
            if section == .running || section == .queued { out.append((section, rows)); continue }
            guard left > 0 else { continue }
            let part = Array(rows.prefix(left))
            left -= part.count
            out.append((section, part))
        }
        return out
    }

    static func total(_ sections: [(JobRowPresentation.Section, [JobRowPresentation])]) -> Int {
        sections.filter { $0.0 != .running && $0.0 != .queued }.reduce(0) { $0 + $1.1.count }
    }
}
