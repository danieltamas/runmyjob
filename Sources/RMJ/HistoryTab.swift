import RMJCore
import SwiftUI

/// Thirty days of settled runs, the same rows as the Jobs tab: open one for its log, rerun a failed one.
struct HistoryTab: View {
    @ObservedObject var model: PanelModel
    /// Rows drawn so far: two hundred expanded rows at once make the panel stall, so more come on request.
    @State private var shown = Self.pageSize
    private static let pageSize = 25

    var body: some View {
        let sections = model.snapshot.historyRows
        if sections.isEmpty {
            EmptyState(symbol: "clock.arrow.circlepath", title: "Nothing older yet",
                       detail: "Runs leave the Jobs tab after two days and stay here for thirty, with their logs.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.page(sections, limit: shown), id: \.0) { section, rows in
                    Eyebrow(text: "\(section.rawValue) - \(sections.first { $0.0 == section }?.1.count ?? rows.count)").padding(.top, 6).padding(.leading, 4)
                    ForEach(rows, id: \.id) { row in
                        JobRowView(row: row, expanded: model.expanded.contains(row.id), model: model) {
                            withAnimation(Motion.snappy) { model.toggle(row.id) }
                        }
                    }
                }
                let total = sections.reduce(0) { $0 + $1.1.count }
                if total > shown {
                    ActionButton(title: "Show \(min(Self.pageSize, total - shown)) more of \(total - shown)", style: .secondary) {
                        shown += Self.pageSize
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// The first `limit` rows across the sections, each section keeping its own heading and count.
    private static func page(_ sections: [(JobRowPresentation.Section, [JobRowPresentation])], limit: Int) -> [(JobRowPresentation.Section, [JobRowPresentation])] {
        var left = limit
        var out: [(JobRowPresentation.Section, [JobRowPresentation])] = []
        for (section, rows) in sections where left > 0 {
            let part = Array(rows.prefix(left))
            left -= part.count
            out.append((section, part))
        }
        return out
    }
}
