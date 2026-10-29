import Foundation

/// A ledger row in the shape of `Job` (docs/AGENT-API.md). Every free-text field is untrusted: it is cleaned here.
enum AgentJob {
    static func text(_ value: String?, limit: Int = 400) -> Any { value.map { UntrustedText.clean($0, limit: limit) } ?? NSNull() }
    static func stamp(_ date: Date?) -> Any { date.map { $0.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) } ?? NSNull() }
    static func number(_ value: Int?) -> Any { value ?? NSNull() }

    static func json(_ job: JobRecord, log: LogArchiveEntry?) -> [String: Any] {
        let github = GitHubJobInfo.decode(job.github)
        let duration: (Any, String) = switch job.duration {
        case .box(let ms): (ms, "box")
        case .mac(let ms): (ms, "mac")
        case .unknown: (NSNull(), "unknown")
        }
        let command: [String: Any] = if let github {
            ["workflow": UntrustedText.clean(job.command, limit: 400), "job": UntrustedText.clean(github.name, limit: 400)]
        } else {
            // The ledger keeps the display form (quoted where needed); a run with --shell is not told apart from one without.
            ["argv": words(job.command).map { UntrustedText.clean($0, limit: 16_384) }, "shell": false]
        }
        return [
            "id": job.id, "source": github == nil ? "rx" : "github", "tenant": text(job.tenant ?? Tenancy.unclassified, limit: 64),
            "repo": text(job.repo), "worktree": text(job.worktree), "branch": text(job.branch), "commit": text(job.commit),
            "dirty": job.worktree == nil ? NSNull() : job.dirty as Any,
            "command": command, "agent": ["kind": text(job.agent ?? "unknown", limit: 64), "session": text(job.session, limit: 128)],
            "location": text(job.location), "fallback_reason": text(job.fallbackReason), "environment": job.environment,
            "rule": text(job.rule), "state": job.state.rawValue, "exit": number(job.exitCode),
            "times": [
                "queued_at": stamp(job.queuedAt), "sync_started_at": stamp(job.syncStartedAt), "sync_ended_at": stamp(job.syncEndedAt),
                "started_at": stamp(job.startedAt), "ended_at": stamp(job.endedAt), "box_started_at": stamp(job.boxStartedAt),
                "box_ended_at": stamp(job.boxEndedAt), "mac_elapsed_ms": number(job.macElapsedMS),
                "clock_offset_ms": number(job.clockOffsetMS), "duration_ms": duration.0, "duration_source": duration.1,
            ] as [String: Any],
            "github": github.map(Self.github) ?? NSNull(),
            "warmth": ["warm", "cold"].contains(job.warmth) ? job.warmth : "unknown",
            "logs": logs(job, entry: log),
        ]
    }

    /// Undoes the quoting of a displayed command: single and double quotes and backslashes, as a POSIX shell reads them.
    static func words(_ display: String) -> [String] {
        var words = [String](), word = "", started = false
        var quote: Character?, escaped = false
        for character in display {
            if escaped { word.append(character); escaped = false; continue }
            if let open = quote {
                if character == open { quote = nil } else if character == "\\", open == "\"" { escaped = true } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character; started = true
            } else if character == "\\" {
                escaped = true; started = true
            } else if character == " " {
                if started { words.append(word); word = ""; started = false }
            } else {
                word.append(character); started = true
            }
        }
        if started { words.append(word) }
        return words
    }

    static func github(_ info: GitHubJobInfo) -> [String: Any] {
        var observation: Any = NSNull()
        if let seen = info.observation {
            func count(_ state: String) -> Int { seen.matches.filter { $0.state == state }.count }
            observation = [
                "online_idle": count("online idle"), "online_busy": count("online busy"),
                "offline_idle": count("offline idle"), "offline_busy": count("offline busy"),
                "offline_idle_names": seen.matches.filter { $0.state == "offline idle" }.map { UntrustedText.clean($0.name) },
                "observed_at": stamp(seen.observedAt), "suspected_cause": text(seen.suspectedCause, limit: 64),
                "dependency_wait": info.waitingOnDependency,
            ] as [String: Any]
        }
        return [
            "run_id": Int(info.runId), "job_id": Int(info.jobId), "run_attempt": info.runAttempt, "status": text(info.status, limit: 64),
            "conclusion": text(info.conclusion, limit: 64), "html_url": text(info.htmlUrl, limit: 400),
            "runner_name": text(info.runnerName), "labels": info.labels.map { UntrustedText.clean($0, limit: 100) },
            "current_step": text(info.currentStep), "steps_done": info.stepsDone, "steps_total": info.stepsTotal,
            "parent_attempt": text(info.parentAttempt, limit: 64), "observation": observation,
        ]
    }

    private static func logs(_ job: JobRecord, entry: LogArchiveEntry?) -> [String: Any] {
        guard let entry else {
            let remote = job.destination != nil
            return ["box": NSNull(), "local": NSNull(), "status": remote ? "pending" : "unavailable",
                    "reason": remote ? NSNull() : "no log archived", "truncated": false]
        }
        let local: Any = entry.status == .available ? "\(job.id).log" : NSNull()
        return ["box": NSNull(), "local": local, "status": entry.status.rawValue, "reason": text(entry.reason), "truncated": entry.truncated]
    }
}
