import Testing
import Foundation
import RMJCore

struct JobRowFilterAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func job(_ id: String, state: JobState = .done, location: String = "box-a",
                     age: TimeInterval = 60) -> JobRecord {
        let at = now.addingTimeInterval(-age)
        var record = JobRecord(id: id, repo: "acme/ledger", command: "swift test",
                               location: location, state: state, queuedAt: at)
        if state != .queued { record.startedAt = at.addingTimeInterval(1) }
        if state.isSettled || state == .lost { record.endedAt = at.addingTimeInterval(2) }
        return record
    }

    private func ids(_ sections: [(JobRowPresentation.Section, [JobRowPresentation])]) -> [String] {
        sections.flatMap { $0.1 }.map(\.id)
    }

    @Test func defaultFilterIsInactiveAndPreservesEverySectionAndRow() {
        let rows = [job("running", state: .running), job("done")].panelRows(now: now)
        // An inactive filter must also preserve an explicitly empty section.
        let sections = rows + [(JobRowPresentation.Section.earlier, [])]
        let filter = JobRowFilter()
        let result = filter.apply(sections)
        #expect(!filter.isActive)
        #expect(result.map { $0.0 } == sections.map { $0.0 })
        #expect(result.map { $0.1 } == sections.map { $0.1 })
        #expect(rows.flatMap { $0.1 }.allSatisfy { filter.matches($0) })
        #expect(!JobRowFilter(query: " \t\n ").isActive)
    }

    @Test func queryRequiresEveryWordAcrossSearchableFields() throws {
        var record = job("job-identifier-42", state: .failed)
        record.command = "swift test --parallel"
        record.branch = "feature/reconcile"
        record.worktree = "ledger-worktree"
        record.commit = "a1b2c3d456789"
        let row = try #require([record].panelRows(now: now).first?.1.first)

        for query in ["ACME ledger", "PARALLEL", "RECONCILE", "LEDGER-WORKTREE",
                      "A1B2C3D", "BOX-A", "FAILED", "JOB-IDENTIFIER-42",
                      "acme parallel reconcile ledger-worktree a1b2c3d box-a failed identifier-42",
                      "  ACME\tledger\nparallel  "] {
            let filter = JobRowFilter(query: query)
            #expect(filter.isActive)
            #expect(filter.matches(row), "Expected query to match: \(query)")
            #expect(ids(filter.apply([(.today, [row])])) == [record.id])
        }
        for query in ["acme nothingelse", "nothingelse acme", "parallel absent"] {
            let filter = JobRowFilter(query: query)
            #expect(!filter.matches(row))
            #expect(filter.apply([(.today, [row])]).isEmpty)
        }
    }

    @Test func queryFoldsCaseAndAccentsInBothDirections() throws {
        var record = job("accented")
        record.repo = "acme/l\u{00E9}dger"
        record.branch = "r\u{00E9}sum\u{00E9}"
        let row = try #require([record].panelRows(now: now).first?.1.first)
        #expect(JobRowFilter(query: "ACME LEDGER RESUME").matches(row))
        #expect(JobRowFilter(query: "\u{00C1}CME L\u{00C9}DGER R\u{00C9}SUM\u{00C9}").matches(row))
        let plain = try #require([job("plain")].panelRows(now: now).first?.1.first)
        #expect(JobRowFilter(query: "\u{00C1}CME L\u{00C9}DGER").matches(plain))
    }

    @Test func kindsSelectOnlyTheirSpecifiedStatesAndOrigins() throws {
        var records = JobState.allCases.map { job($0.rawValue, state: $0) }
        records.append(job("local-done", location: "local"))
        var github = job("github-failed", state: .failed, location: "box-a")
        github.github = #"{"repo":"acme/ledger","name":"test","runId":1,"jobId":2,"runAttempt":1,"status":"completed","conclusion":"failure","labels":[],"stepsDone":0,"stepsTotal":0,"waitingOnDependency":false}"#
        #expect(try #require(GitHubJobInfo.decode(github.github)).jobId == 2)
        records.append(github)
        // A location string alone is not a GitHub job record.
        records.append(job("hosted-without-record", location: "github-hosted"))
        let sections = records.panelRows(now: now)
        let rows = sections.flatMap { $0.1 }
        let cases: [(JobRowFilter.Kind, Set<String>)] = [
            (.all, Set(records.map(\.id))),
            (.failed, ["failed", "lost", "github-failed"]),
            (.done, ["done", "local-done", "hosted-without-record"]),
            (.github, ["github-failed"]),
            (.local, ["local-done"])
        ]
        for (kind, expected) in cases {
            let filter = JobRowFilter(kind: kind)
            #expect(filter.isActive == (kind != .all))
            #expect(Set(ids(filter.apply(sections))) == expected)
            for row in rows {
                #expect(filter.matches(row) == expected.contains(row.id))
            }
        }
        for (kind, query, expected) in [
            (JobRowFilter.Kind.failed, "lost", ["lost"]),
            (.done, "local", ["local-done"]),
            (.github, "acme failed", ["github-failed"]),
            (.local, "ledger done", ["local-done"]),
            (.failed, "swift nothingelse", []),
            (.done, "lost", []),
            (.github, "hosted-without-record", []),
            (.local, "github-failed", [])
        ] {
            let filter = JobRowFilter(query: query, kind: kind)
            #expect(ids(filter.apply(sections)) == expected)
            for row in rows {
                #expect(filter.matches(row) == expected.contains(row.id))
            }
        }
    }

    @Test func filteringDropsEmptySectionsAndPreservesInputOrder() {
        let first = JobRowPresentation(job("first", state: .failed), now: now)
        let second = JobRowPresentation(job("second", state: .lost), now: now)
        let third = JobRowPresentation(job("third", state: .failed), now: now)
        let done = JobRowPresentation(job("done"), now: now)
        // Deliberately use noncanonical order to detect sorting by the filter.
        let sections: [(JobRowPresentation.Section, [JobRowPresentation])] = [
            (.earlier, [second, done, first]), (.queued, []),
            (.running, [done]), (.today, [third])
        ]
        let result = JobRowFilter(kind: .failed).apply(sections)
        #expect(result.map { $0.0 } == [.earlier, .today])
        #expect(result.map { $0.1 } == [[second, first], [third]])
        #expect(JobRowFilter(query: "nothingelse").apply(sections).isEmpty)
    }

    @Test func allRowsCombinesLiveJobsAndHistoryExactlyOnceInSectionOrder() {
        let tailnet = TailnetState.parse(Data(#"{"BackendState":"Stopped"}"#.utf8), readAt: now)
        var snapshot = PanelSnapshot(now: now, tailnet: tailnet, jobs: [
            job("today", age: 10), job("queued", state: .queued, age: 20),
            job("running", state: .running, age: 30)
        ])
        // Oldest first in the input makes chronological ordering observable.
        snapshot.history = [job("day-29", age: 29 * 86_400), job("day-5", age: 5 * 86_400)]
        let sections = snapshot.allRows
        #expect(sections.map { $0.0 } == [.running, .queued, .today, .earlier])
        #expect(sections.map { $0.1.map(\.id) } == [
            ["running"], ["queued"], ["today"], ["day-5", "day-29"]
        ])
        let allIDs = ids(sections)
        #expect(allIDs.count == 5)
        #expect(Set(allIDs) == ["running", "queued", "today", "day-5", "day-29"])
        for id in ["running", "queued", "today", "day-5", "day-29"] {
            #expect(allIDs.filter { $0 == id }.count == 1)
        }
    }
}
