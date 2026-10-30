# Box card image list, 2026-10-30

Codex read-only review of the diff:

- P2 profile images hidden (fixed: DestinationLoader takes the ProfileStore and counts the images of profiles of rules routed to the box; tests added).
- P2 missing-tools warnings of a now-hidden image stay until the next probe (accepted: the probe runs every 5 minutes and checks only images rules or the catalog name).
