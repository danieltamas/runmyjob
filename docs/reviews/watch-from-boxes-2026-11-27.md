# Watch repos from the boxes, not from tenant owners - Codex review 2026-11-27

## Round 1

P1 Sources/RMJCore/Net/DestinationProbeTiers.swift:46 - Dash echo interprets workflow-controlled backslash escapes: a repository value containing \n@@images rc=0 injects probe sections before Swift validates sightings, allowing forged health readings -> Validate both fields before emission and use printf with a fixed format.
P1 Sources/RMJCore/Net/DestinationProbeTiers.swift:44 - The 4000-line limit does not bound bytes or execution time; a workflow can plant a lexically last Worker_*.log containing an enormous line, blocking the entire stream and repeating the failure after reconnect -> Enforce byte and execution-time limits inside the container and bound work per heavy turn.
P2 Sources/RMJCore/Net/DestinationProbeTiers.swift:36 - rw marks workers consumed before their logs are successfully read; transient Docker/cgroup failures or an incomplete initial log permanently suppress discovery for those workers during the session -> Track successful reads separately and retry failed or incomplete reads with bounded backoff.
P2 Sources/RMJCore/GitHub/GitHubPoller.swift:100 - An org-only repo without recent ledger history is undiscoverable while its first job remains queued; jobs completed during downtime can also remain undiscovered, losing U5 queue diagnostics and backfill -> Provide bounded discovery independent of live workers, or require explicit repo/glob coverage for org targets.
P2 Sources/RMJCore/GitHub/GitHubPoller.swift:127 - An org target admits unlimited fabricated same-owner repo names for 30 days; failed polls retain these claims and retry every 120 seconds, allowing untrusted sightings to consume polling capacity -> Preserve runID, bound pending claims per destination, verify them against GitHub, and evict rejected claims.
P2 Sources/RMJCore/GitHub/AppBackground.swift:69 - noteRunnerJobs can add reports while the loop awaits noteBoxRepos; the subsequent unconditional clear deletes reports absent from the iteration's snapshot -> Snapshot and clear boxReports before the first await, then drain that snapshot.
P2 Sources/RMJCore/GitHub/AppBackground.swift:67 - A sighting refreshes the watched list but leaves an existing repo's due time and priority unchanged, delaying its running job by up to five minutes -> Deduplicate sightings by destination/runID across cached-section replays, then make each newly observed run's repo immediately due.
TOTAL P0=0 P1=2 P2=5 P3=0
Fixes: printf + in-container validation and Swift-side tamper drop; head -c 1 MB, 4000 lines, timeout around docker exec; one retry via $tw; boxRepos capped at 100; reports snapshotted before await; sightings deduped by run id and made due now. Accepted: an org repo that never used a runner stays invisible until a runner picks its first job.

## Round 2

P2 Tests/RMJCoreTests/RunnerJobSightingAcceptanceTests.swift:49 - `rw` is now assigned after the Docker read, so assertions at lines 52, 55 and 56 all fail -> update the test to verify scan/read execution in the loop shell and the two-attempt retry behavior.
P2 Sources/RMJCore/GitHub/GitHubPoller.swift:178 - Any polling error evicts a newly discovered repo, including transient network/5xx failures; watch-list refresh removes it before the 120-second retry, and run-ID deduplication suppresses replay -> retain and retry transient failures; evict only definitively rejected repositories.
P2 Sources/RMJCore/Net/DestinationProbeTiers.swift:46 - The 10-second timeout applies per worker, with no total scan budget; several stalled reads exceed the stream's 30-second silence deadline or the one-shot probe's 20-second timeout, causing discarded frames and repeated discovery after reconnect -> bound total discovery time and defer remaining workers.
TOTAL P0=0 P1=0 P2=3 P3=0
Fixes: scan assigns $rw (kept workers), the read adds successful ones; a box repo is dropped only on a 404 run listing; at most 2 worker reads per heavy turn, 8 s each.
