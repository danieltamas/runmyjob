# Review: stale done marker and runner_labels (Codex, 2026-10-31)

Scope: GitHubPoller.swift, Rules.swift, RulesValidation.swift, RunnerCompose.swift, RunnerStack.swift, DestinationSetup.swift, OpsCommand.swift.
Result after fixes: PASS (one round; both findings fixed, check.sh ok, 530 tests).

- P2 fixed: a completed run whose job GitHub never settles was re-fetched forever. A marker written later than the settle window (1 h) after the run's last update is a give-up and stays final; one written inside it (the race that stuck the rows) is re-checked.
- P2 fixed: runner_labels keys differing only in case were silently merged; validation rejects them.
