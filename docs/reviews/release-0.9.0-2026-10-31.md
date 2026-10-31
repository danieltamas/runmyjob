# Codex review before release 0.9.0 (2026-10-31)

Scope: the whole uncommitted diff (ssh, host-key trust, Keychain, tenants, autoscale, runner extras, probe scripts, command guard, wizard rollback). Read-only review by Codex; findings as reported.

## Fixed before the release (tests: ReviewFixesAcceptanceTests)
- P1 HostKeyTrust: a hashed known_hosts entry hid the stored key, so a changed key could be appended. `trust` now asks `ssh-keygen -F` when hashed lines exist and refuses a different key.
- P1 AddDestination: a new tenant could claim an org another tenant already owns. The add now fails at the `tenant` step.
- P1 RunnerScalingLoop: an ambiguous owner (two tenants) resolved to unclassified, which the deny permits. Ambiguous is now denied.
- P2 RunnerStack: `sha256sum` now gets `--`, so an extras file name starting with `-` cannot be read as an option.
- P2 CommandGuard: `pnpm -r test`, `npm --prefix web test`, `--filter`, `--cwd` and similar flags between the manager and the subcommand now route.
- P2 DestinationWizard: a box that went offline between onboarding and setup left the new destination and tenant; it is now discarded.

## Not fixed, owner informed
- P1 Keychain.swift: a PAT is passed in `security add-generic-password -w <value>`, so it is in the process arguments for the milliseconds of a save. The acceptance tests pin that argv. Alternative: `security -i` with the command on stdin; needs a spec and test change. Risk: another local process reading arguments during a save.
- P1 BurstRunners.swift: `GH_PAT` as a container environment variable lives in the container's configuration until removal (readable with `docker inspect` by a user in the docker group on the box). Compose-run static runners do the same; the entrypoint unsets it inside the container. Passing it through a file mounted tmpfs is the alternative.
- P2 RunnerStack.swift: deleting an extras file locally is not seen as drift (a removed file's services keep running until the next deploy that changes something).
