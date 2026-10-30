# rx-python and rx-go images, 2026-10-30

Codex read-only review of the final diff:

- P2 Support/box/images/go/Dockerfile: GOPATH and GOCACHE under /home/rx fail when the box user is not uid 1000 (fixed: HOME, GOPATH, GOCACHE under /tmp; same HOME for rx-python). Verified: `go test` and `pytest` pass in the images as uid 4321.

Note: BuildEnvironmentsAcceptanceTests.swift was updated by hand (4 images) because a stale Codex claim from 2026-10-29 blocked Codex from editing it.
