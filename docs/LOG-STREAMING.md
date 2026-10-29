# Log streaming (approved 2026-10-29)

Optional and off by default: RMJ sends a run's log lines, as they happen, to one or more log ingestors the owner
configures. Decided by the owner on 2026-10-29: the three ingestors below, a disk spool that drains empty, a sink names its tenants,
repo and agent fields travel with every line, shipped as 0.2.0.

## Complete when

With a Loki, a Datadog and an Elasticsearch sink enabled (each pointed at a local fake or a real instance), one
`rmj run -- <command>` makes every output line appear in all three, in each one's own format, within 2 seconds of
being printed. A job of a tenant a sink is not scoped to reaches no byte of it. The panel header shows a small
broadcast glyph while any sink is on, and turns amber when one fails. With every sink off or removed the app makes no
new network call.

## Measured by

- `swift test --filter LogSink`: the formats, the queue, the retry rules and the tenant deny, against a fake HTTP
  transport (no network).
- `scripts/sinks-check.sh`: starts three tiny local HTTP receivers (one per format), runs a 650-line job, and checks
  the line count, the order and the first line's fields in each. Prints one `sinks: ok` line.
- `scripts/perf.sh` with the three local sinks on: streaming CPU stays under 2 percent, idle under 0.4 percent.
- README screenshot of the Settings pane and the header glyph, rendered by `--render-screenshots`.

## The top three

| Ingestor | Why | Endpoint and body | Auth |
| --- | --- | --- | --- |
| Grafana Loki (self-hosted or Grafana Cloud) | The common self-hosted choice; fits a tailnet box | `POST <url>/loki/api/v1/push`, JSON `{"streams":[{"stream":{labels},"values":[["<unix ns>","<line>"]]}]}` | none, basic (user and token), bearer; optional `X-Scope-OrgID` |
| Datadog Logs | The common hosted choice | `POST https://http-intake.logs.<site>/api/v2/logs`, JSON array of `{ddsource, ddtags, hostname, service, status, message, timestamp}`; at most 1000 entries and 5 MB a request | `DD-API-KEY` header; the site picks the host (`datadoghq.com`, `datadoghq.eu`, `us3`, `us5`, `ap1`) |
| Elasticsearch or OpenSearch | The other self-hosted default | `POST <url>/_bulk`, NDJSON pairs `{"create":{"_index":"rmj-logs"}}` and `{"@timestamp","message","log.level","service.name","rmj":{...}}`; the response's per-item status is read | `ApiKey` header or basic |

Next in line, not in this plan: Splunk HEC, OTLP/HTTP, syslog.

Every entry carries: the line, its time, a level from RMJ's own classifier (error, warn, info), `service=rmj`, and
the run's tenant, repo, branch, agent, destination and job id. Loki keeps only low-cardinality fields as labels
(app, tenant, repo, destination, level); the job id and line number go in the line as JSON. When a run settles one
more entry says how it ended: state, exit code, duration, average CPU and memory.

## Layout (units, in order)

1. **Sink config and secrets.** `log_sinks` in `config.json`: `id`, `kind` (`loki`, `datadog`, `elasticsearch`),
   `name`, `url` (or `site` for Datadog), `enabled`, `tenants` (a list, or `all: true`, never implied), auth kind
   and its non-secret part (user name, org id, index). The password, token or API key lives in the Keychain under
   `rmj.sink.<id>`, never in `config.json`, a log, the ledger or a notification. Validation: HTTPS only, except
   loopback and tailnet addresses; no redirect is followed; at least one tenant or `all`.
2. **Formats.** One pure function per kind from a batch of entries to a `URLRequest` (method, URL, headers, body).
   Batch limits per kind (Datadog 500 entries, all 1 MB).
3. **Spool and shipper.** Every enabled sink has its own spool, `~/.rmj/spool/<sink id>/` (directory 0700, files 0600): a
   producer writes each batch of entries (every second or 500 lines, one entry per line of output) as one file, by
   write then rename, so a file is whole or absent. A drainer sends the oldest file first and deletes it only after a
   2xx answer (at least once; Elasticsearch gets a stable `_id` of job and line so a repeat is not a duplicate, Loki
   drops an identical repeat). One drainer per sink at a time, by a lock on `<sink id>/.lock`: the CLI drains while
   its run lasts and for 3 seconds after it, the app drains whatever is left every 5 seconds and when a sink is
   switched on, so the spool is watched for as long as the app runs and also drained by the next `rmj run`. The pool
   is managed: a cap of 256 MB per sink (fixed, the oldest file dropped and counted when it is full), files
   older than 7 days dropped and counted, stray `.tmp` files swept after an hour. Disabling a sink pauses it (its
   spool is kept, shown as `paused, N waiting`) and nothing new is written to it; enabling it drains it; removing a
   sink asks first and deletes its spool. With every sink disabled the spools drain or sit paused and no new file is
   written. Failure rules: 5xx, 429, 408 and network errors back off 1 s doubling to 5 minutes (`Retry-After`
   honoured) and the file stays; 401 and 403 pause the sink as `auth failed` (no hammering); another 4xx moves that
   file to `rejected/` (the newest 50 kept, counted) so one bad batch never blocks the queue. Request timeout 5
   seconds. An Elasticsearch 2xx counts as delivered only when its body is the bulk answer JSON with `errors: false`
   (a body that cannot be read is retried; with `errors: true` an item 409 counts as delivered, 401/403 pause, 408/429/5xx
   retry, any other item status rejects). Every queued line carries its tenant and is checked against the sink's current scope right before it is sent: when the
   sink's scope changes, what no longer matches is dropped, never sent. Nothing in this path can fail or delay a job beyond the 3 second end flush.
4. **Wiring.** `OutputPump` feeds the shippers after redaction (the same `SecretRedactor` and `LogSanitizer` the
   screen gets), so local and box runs stream live from the process that runs them, the CLI included. GitHub logs
   are sent when `LogArchive` stores them, with GitHub's own timestamps. Status (sent, dropped, last ok, last error)
   goes to `~/.rmj/log-sinks.json` (sent, rejected, dropped, waiting files and lines, oldest age, last ok, last error), written
   at most every 5 seconds.
5. **App.** Settings > Log streaming: the list with what is waiting per sink, an Add sheet per kind, a toggle, Send test line
   (shows the HTTP status), Drain now, Discard waiting, Remove. The header glyph: teal while any sink is on and healthy, amber after a failure in the last 5
   minutes or while a backlog is older than 5 minutes, absent when none; its tooltip names the sinks and their counts. The run report names the sinks a run
   was sent to. `rmj sinks` lists them with status, `rmj sinks test <id>` sends the test line; adding a sink needs
   the app (no secret on a command line).
6. **Docs and release.** README section and screenshot, SECURITY.md, ARCHITECTURE.md, PLAN.md non-goals, LOG.md,
   release 0.2.0 by `docs/RELEASE.md`.

## Acceptance (turned into tests by Codex before implementation)

- Each format's request for a fixed batch is byte-exact (method, URL, headers, body), including a line with quotes,
  newlines escaped, non-ASCII and a 1 MB line (truncated with a marker).
- A sink scoped to tenant `a` receives nothing of a tenant `b` job or of a job with no tenant; `all: true` receives
  both; a sink with an empty scope receives nothing and the Add sheet will not save it.
- Known secrets (the PATs the redactor already knows) never appear in a request body.
- Spool: a batch survives a restart (reopen the spool, same files); a file is deleted only after a 2xx; a transport
  failure leaves it; 503 then 200 sends it once more and empties the spool; 401 pauses the sink and keeps the
  files; 400 moves one file to `rejected/` and the next file is sent; 429 honours `Retry-After`.
- Management: over the cap the oldest file is dropped and counted; files past 7 days are dropped and counted; a
  disabled sink gets no new file and keeps its old ones; enabling it drains them in order; removing deletes the
  spool; two drainers on one spool never send the same file twice (the lock).
- Elasticsearch `_id` is stable for a job and line, so the bulk body of a retried batch is identical.
- A failing sink never delays a run's exit by more than the 3 second flush.
- Two sinks at once: one down, one up; the up one gets every line, in order.
- `http://` to a public address is refused; `http://127.0.0.1` and a `100.x` address are allowed; a 302 is not
  followed.
- With no sink configured the shipper starts no task and opens no connection.
- The indicator state is a pure function of config and status: none, healthy, failing.

## Quality criteria

- Code: files under 500 lines, no third-party packages (`URLSession`), the existing idioms (`ConfigFile`, `Keychain`,
  the Settings parts); the encoders are pure and tested without a network.
- Speed: idle CPU under 0.4 percent and streaming under 2 percent with three sinks on, by `scripts/perf.sh`; a
  sink never adds latency to the command's own output.
- Security: logs leave the Mac only to a URL the owner typed, only for the tenants chosen, redacted and sanitized;
  credentials only in the Keychain and in the one request header; TLS verified; the two-companies rule holds
  (a tenant deny test); SECURITY.md states that this is the one outbound path that carries job output, and that it
  is off by default. It does not carry jobs, so the tailnet-only rule for destinations is unchanged.

## Decisions

1. Settled: Loki, Datadog, Elasticsearch/OpenSearch (Splunk HEC next).
2. Settled: a disk spool per sink that is watched and drained empty (above).
3. Settled: a sink must name its tenants (or `all`) before it can be saved.
4. Settled: repo, branch, agent and destination travel with every line.
5. Settled: ship as 0.2.0.
