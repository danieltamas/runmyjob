import RMJCore
import SwiftUI

/// Thirty days of settled runs, the same rows as the Jobs tab: open one for its log, rerun a failed one.
struct HistoryTab: View {
    @ObservedObject var model: PanelModel
    /// Rows drawn so far: two hundred expanded rows at once make the panel stall, so more come on request.
    @State private var shown = RowPaging.pageSize

    var body: some View {
        let sections = model.snapshot.historyRows
        if sections.isEmpty {
            EmptyState(symbol: "clock.arrow.circlepath", title: "Nothing older yet",
                       detail: "Runs leave the Jobs tab after two days and stay here for thirty, with their logs.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(RowPaging.page(sections, limit: shown), id: \.0) { section, rows in
                    Eyebrow(text: "\(section.rawValue) - \(sections.first { $0.0 == section }?.1.count ?? rows.count)").padding(.top, 6).padding(.leading, 4)
                    ForEach(rows, id: \.id) { row in
                        JobRowView(row: row, expanded: model.expanded.contains(row.id), model: model) {
                            withAnimation(Motion.snappy) { model.toggle(row.id) }
                        }
                    }
                }
                let total = RowPaging.total(sections)
                if total > shown {
                    ActionButton(title: "Show \(min(RowPaging.pageSize, total - shown)) more of \(total - shown)", style: .secondary) {
                        shown += RowPaging.pageSize
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
