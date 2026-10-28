# Codex review, runner compose, rule editor, buttons (2026-10-28, round 2)

P1 Sources/RMJCore/Ops/RunnerCompose.swift:92 - Destination names are interpolated into YAML without escaping - A rules.json destination name containing `box\n      LEAK: ${GH_PAT_DANIELTAMAS}` injects an environment variable carrying the PAT into the runner, surviving the entrypoint's `unset GH_PAT` - Encode dynamic YAML values as quoted scalars and reject interpolation syntax.

P2 Sources/RMJCore/Ops/RunnerCompose.swift:71 - The fallback service name is not checked for uniqueness - Targets ordered as `x/bob-app`, `alice/app`, `bob/app` generate `runner-bob-app` twice, producing duplicate YAML service keys and preventing reliable deployment - Allocate names against the complete taken set until unique.

P2 Sources/RMJCore/Ops/RunnerStack.swift:105 - Deploy does not reconcile the desired runner service set - Switching between bundled targets sharing the same owner's PAT can leave every file hash unchanged, so deployment returns without starting the newly selected runner or stopping the removed one; generated target removal also leaves old containers running - Compare desired services with deployed state and reconcile additions and removals after checking affected runners are idle.

P2 Sources/RMJCore/Routing/RuleEditing.swift:70 - The concurrency fingerprint is read when applying the edit instead of retained from editor load - Another process can reorder or modify a valid rules file while the editor is open, after which Save or Delete silently modifies the rule now occupying the old index - Pass the original fingerprint and rule identity into apply and reject stale edits.

P2 Sources/RMJ/RuleEditor.swift:40 - Moving a rule leaves the editor attached to its previous index - Editing rule B at index 1, pressing Up, then Delete deletes rule A now at index 1; Save can instead fail on B's duplicate name - Move the editor's selection with the rule or close and reopen it at its new position.

P2 Sources/RMJ/DestinationWizard.swift:163 - PAT grouping covers only missing targets and ignores existing credentials for the same owner - With a stored PAT for `alice/one`, adding `alice/two` prompts again; entering another valid PAT makes deployment fail because both targets map to `GH_PAT_ALICE` with different values - Reuse the existing owner's PAT across its targets, or replace all credentials in that owner group together.

COUNT P0-P2: 6
Fixed: all six (YAML injection by validating targets and sanitising host; unique fallback names; .rmj-services manifest + rm of unused bundled runners + --remove-orphans; rule editor keeps the opened fingerprint and closes after a move; PAT reused across an owner's targets). Re-verified: 204 tests, check.sh ok.
