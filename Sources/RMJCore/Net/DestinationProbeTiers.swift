import Foundation

/// The box's audit log records every process a login session starts, and a stream lives for days: what a frame starts costs
/// one log line each, forever. So the stream's heavy and rare tiers start as few processes as they can. The light tier starts
/// none (see `lightCommands`); this file is the rest.
extension DestinationProbe {
    /// Facts that cannot change while a session lasts: read once, replayed on every later turn of their tier. The value is the
    /// `case` pattern of the exit statuses that are kept (`systemd-detect-virt` exits 1 and prints `none` on bare metal). A
    /// status outside it is read again on the next turn, so a tool installed later is still found. A pattern, not `[ -le ]`:
    /// the stream script must carry no ` -l` (a listener flag; `BoxStreamAcceptanceTests`).
    private static let sessionFacts: [String: String] = ["rsync": "0", "nproc": "0", "osname": "0", "virt": "0|1"]

    /// The commands that differ from the one-shot probe's. They print the same lines.
    private static let streamCommands: [String: String] = [
        // One `docker ps` for the three sets (a rx job, an RMJ job, a runner) instead of one each plus a dedup. Labels print as
        // `k=v,k=v`, and `--label rx` has an empty value, so a key is found by its `=`.
        "containers": #"ps=$(docker ps --format '{{.ID}} {{.Names}} {{.Labels}}') "#
            + #"&& ids=$(printf '%s\n' "$ps" | while read -r id nm lb; do case ",$lb" in (*,rx=*|*,rmj.job=*) echo "$id";; (*) case $nm in (runner-*) echo "$id";; esac;; esac; done) "#
            + #"&& { [ -z "$ids" ] || docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' $ids; }"#,
        // The same four signals; `df | awk`, `lsblk | awk` and `smartctl | grep` become shell reads, and the disk list, which a
        // session cannot change, is read once into `$dsk` by `diskList`.
        "diskhealth": #"o=$(findmnt -no OPTIONS -T "$HOME" 2>/dev/null) && { case ",$o," in (*,ro,*) echo ro 1;; (*) echo ro 0;; esac; }; "#
            + #"set -- $(df -Pi "$HOME"); [ $# -ge 6 ] && { shift $(($# - 6)); echo "inodes ${5%\%}"; }; "#
            + #"m=$(dmesg 2>/dev/null) && [ -n "$m" ] && echo "ioerr $(printf '%s\n' "$m" | grep -ciE 'i/o error|ext4-fs error|xfs.*(corrupt|error)|btrfs.*error|blk_update_request|nvme.*(timeout|reset)')"; "#
            + #"for d in $dsk; do r=$(smartctl -H "$d" 2>/dev/null | while read -r l; do case $l in (*[Oo]verall-health*|*SMART\ Health\ Status*) echo "$l";; esac; done); "#
            + #"case "$r" in (*FAILED*) echo smart failed;; (*PASSED*|*OK*) echo smart passed;; esac; done; true"#,
    ]

    /// The disks `smartctl` is asked about, listed once per session and only where `smartctl` exists.
    private static let diskList = #"[ -n "${dsk+x}" ] || { dsk=; command -v smartctl >/dev/null 2>&1 && dsk=$(lsblk -dno NAME,TYPE 2>/dev/null | while read -r nm ty; do [ "$ty" = disk ] && echo "/dev/$nm"; done); }; "#

    static func streamCommand(_ name: String, default command: String) -> String { streamCommands[name] ?? command }

    /// The `Runner.Worker` processes on the box, found with shell builtins only: the pids not in `$rw` (the workers already read)
    /// go to `$nw`, and `$rw` keeps only the ones still running. A worker is one job; it lives as long as the job.
    static let runnerWorkerScan = #"nw=; kw=; for p in /proc/[0-9]*; do read -r c < "$p/comm" || continue; [ "$c" = Runner.Worker ] || continue; "#
        + #"p=${p#/proc/}; case "$rw" in (*" $p "*) kw="$kw $p ";; (*) nw="$nw $p";; esac; done 2>/dev/null; rw=$kw"#

    /// For up to two workers in `$nw` (the rest wait for the next heavy turn, so a turn stays well inside the stream's silence
    /// limit): the container from the cgroup file, then one `docker exec` (8 s at most) that prints `<owner/name> <run id>` from
    /// the newest `_diag/Worker_*.log`: the job message sits near line 1000, and the read stops at 1 MB or 4000 lines. Workflow
    /// steps can write that log, so both fields are checked in the container before `printf` prints them (a name with a
    /// backslash or `@` never reaches the frame) and the line stays a claim (`RunnerJobSighting`). Runs in the loop's own
    /// shell: a worker read joins `$rw`; one that printed nothing is tried once more on the next heavy turn (`$tw`), then
    /// given up, so a job costs at most two reads. Sightings collect in `$out`.
    static let runnerWorkerRead = #"out=; ntw=; m=0; for p in $nw; do [ $m -eq 2 ] && break; m=$((m+1)); cid=; while read -r l; do case $l in (*docker-*.scope) l=${l##*docker-}; cid=${l%.scope};; "#
        + #"(*/docker/*) cid=${l##*/docker/};; esac; done < "/proc/$p/cgroup"; r=; case $cid in (''|*[!0-9a-f]*) ;; (*) "#
        + #"r=$(timeout 8 docker exec "$cid" sh -c 'cd /home/runner 2>/dev/null; f=; for x in _diag/Worker_*.log; do f=$x; done; [ -f "$f" ] || exit 0; "#
        + #"head -c 1048576 "$f" | { n=0; k=; r=; id=; while [ $n -ne 4000 ] && IFS= read -r l; do n=$((n+1)); case $l in (*\"k\":\ \"repository\"*) k=r;; "#
        + #"(*\"k\":\ \"run_id\"*) k=i;; (*\"v\":\ \"*) v=${l#*\"v\":\ \"}; v=${v%%\"*}; case $k in (r) r=$v;; (i) id=$v;; esac; k=;; "#
        + #"(*) k=;; esac; [ -n "$r" ] && [ -n "$id" ] && break; done; case $r in (*/*/*|*[!A-Za-z0-9._/-]*|/*|*/) r=;; esac; "#
        + #"case $id in (*[!0-9]*) id=;; esac; [ -n "$r" ] && [ -n "$id" ] && printf "%s %s\n" "$r" "$id"; }');; esac; "#
        + #"if [ -n "$r" ]; then out="$out$r$nl"; rw="$rw $p "; else case "$tw" in (*" $p "*) rw="$rw $p ";; (*) ntw="$ntw $p ";; esac; fi; "#
        + #"done 2>/dev/null; tw=$ntw"#

    /// `$out` capped at `bodyCap`. bash cuts it with a parameter expansion; any other shell pipes it through `head`.
    static var capFunction: String {
        #"cap() { if [ -n "$BASH_VERSION" ]; then eval 'printf "%s\n" "${out:0:\#(bodyCap)}"'; else printf '%s\n' "$out" | head -c \#(bodyCap); fi; }"#
    }

    /// One heavy or rare step: its status in a header and its capped output. Always one line, so a tier stays one block.
    static func streamWrapped(_ step: (name: String, command: String)) -> String {
        let header = #"printf '@@\#(step.name) rc=%s\n' "$rc"; cap; echo"#
        let run = "out=$(\(step.command) 2>&1); rc=$?"
        switch step.name {
        case let name where sessionFacts[name] != nil:
            let held = "c_\(name)", keep = sessionFacts[name] ?? "0"
            return #"if [ -z "$\#(held)" ]; then \#(run); case $rc in (\#(keep)) \#(held)="$rc:$out";; esac; else rc=${\#(held)%%:*}; out=${\#(held)#*:}; fi; \#(header)"#
        case "tools":
            // Images change when someone pulls or builds one: asked for on the first rare turn and every third one after, replayed
            // in between (the replay keeps the section inside its three-period life).
            return #"if [ -z "$c_tools" ] || [ $((i % (3 * rare_every))) -eq 0 ]; then \#(run); c_tools="$rc:$out"; else rc=${c_tools%%:*}; out=${c_tools#*:}; fi; \#(header)"#
        case "containers":
            return "\(run); ps_rc=$rc; \(header)"
        case "docker":
            // The containers step ran first: a `docker ps` that worked says the daemon answers, and the version it reported is
            // asked for again only when it was never read, when that failed, and on the rare tier's turns.
            return #"if [ -n "$dv" ] && [ "$ps_rc" = 0 ] && [ $((i % rare_every)) -ne 0 ]; then rc=0; out=$dv; else \#(run); dv=; [ $rc -eq 0 ] && dv=$out; fi; \#(header)"#
        case "diskhealth":
            return "\(diskList)\(run); \(header)"
        case "runnerjobs":
            // Scan and read run in the loop's own shell, so `$rw` and `$tw` outlive the turn: a job costs one `docker exec`, twice at most.
            return "\(runnerWorkerScan); \(runnerWorkerRead); rc=0; \(header)"
        default:
            return "\(run); \(header)"
        }
    }

    /// Everything before the loop: the turn counter, the two periods the light and heavy snippets read, `cap`, and the sleep.
    /// bash waits with `read -t` on a coprocess that never writes (a built-in that starts no program); anything else, or a
    /// coprocess that died, waits with `sleep`.
    static func streamPrologue(rareEvery: Int) -> [String] {
        ["i=0", "nl='", "'", "disk_every=\(max(1, rareEvery))", "rare_every=\(max(1, rareEvery))", capFunction, "nap=0",
         #"if [ -n "$BASH_VERSION" ]; then eval 'coproc NAP { read -r _; }' 2>/dev/null && eval 'napfd=${NAP[0]}' && nap=1; fi"#]
    }

    static func streamWait(_ interval: Int) -> String {
        #"if [ "$nap" = 1 ]; then read -t \#(interval) -u "$napfd" _; [ $? -gt 128 ] || sleep \#(interval) || exit 1; else sleep \#(interval) || exit 1; fi"#
    }
}
