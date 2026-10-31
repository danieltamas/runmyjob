# Autoscale (burst runners) - Codex review, 2026-10-31

Read-only review of RunnerScaler, BurstRunners, RunnerScaling, RunnerScalingLoop and the AppBackground call.

Fixed:
- P1 failed GitHub listing made a burst look unregistered (removed after 180 s): a burst of a target whose runners could not be listed counts as busy.
- P1 docker listing failures hid bursts (cap bypass): `docker ps`/`inspect` failure now exits non-zero and the box is skipped.
- P1 memory accounting ignored existing bursts: each running burst adds 8 GiB to the box's committed memory.
- P1 org target ignored the job's company: a job and a destination of different companies never match (assign, label union and box targets).
- P2 scaling blocked the app loop: it runs in its own task, one round at a time.
- P2 an unreadable box cleared the burst watch: cleanup rounds continue while any box could not be read (every 60 s when no job is queued).
- P2 label union across boxes: the box-name label no longer counts, only the target's derived and extra labels, and only from destinations of the job's company.
- P2 label collision: bursts use the static runner's service name (same derivation as the deploy).

Accepted: P1 `stop` removes by name. Names carry the `burst-` prefix RMJ owns and a 6-hex suffix; reuse by an unrelated container needs a hand-named lookalike. The acceptance test pins the exact `docker rm -f <name>` command.
