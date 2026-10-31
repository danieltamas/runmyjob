# Review: Keychain through /usr/bin/security (Codex, 2026-10-31)

Scope: Sources/RMJCore/Support/Keychain.swift and its callers. Result: PASS.

- No actionable findings.
- Note (P3, fails closed): output larger than the pipe buffer blocks the tool until the timeout and reads as `.denied`. Secrets and a status line are far below it.
- Not exercised: the real macOS GUI prompt.
- Test fix: the timeout test used 300 ms, shorter than the fake script's startup under parallel load; Codex raised it to 2 s and polls for the pid file (patch applied unchanged).
