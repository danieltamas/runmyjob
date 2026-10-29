#!/usr/bin/env bash
# Log streaming end to end (docs/LOG-STREAMING.md, "Measured by"): two local receivers (Loki and Elasticsearch; Datadog's
# intake host is fixed, so its request is pinned byte for byte by the unit tests), one 650-line `rmj run`, and the
# check that every line arrived in each, in order, with its fields. Prints one `sinks: ok` line.
#   sinks-check.sh [path/to/rmj]    (default: $RMJ_CLI, else the debug build in ~/.cache/rmj-build)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
rmj=${1:-${RMJ_CLI:-$HOME/.cache/rmj-build/debug/RMJCLI}}
[[ -x $rmj ]] || { echo "sinks: $rmj is missing (swift build first)" >&2; exit 2; }

work=$(mktemp -d)
pids=()
cleanup() { for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT

lokiPort=$((20000 + RANDOM % 10000)); esPort=$((lokiPort + 1))
python3 -I "$root/scripts/sinks-receiver.py" loki "$lokiPort" "$work/loki.jsonl" & pids+=($!)
python3 -I "$root/scripts/sinks-receiver.py" elasticsearch "$esPort" "$work/es.jsonl" & pids+=($!)

mkdir -p "$work/home"
cat > "$work/home/config.json" <<JSON
{"log_sinks": [
  {"id": "loki-check", "kind": "loki", "name": "Loki", "url": "http://127.0.0.1:$lokiPort", "all": true},
  {"id": "es-check", "kind": "elasticsearch", "name": "Elasticsearch", "url": "http://127.0.0.1:$esPort", "all": true}
]}
JSON
sleep 1

(cd "$root" && RMJ_HOME="$work/home" "$rmj" run -- sh -c 'i=1; while [ $i -le 650 ]; do echo "check line $i"; i=$((i+1)); done' >/dev/null)

python3 -I - "$work" <<'PY'
import json, sys
work = sys.argv[1]
def rows(name): return [json.loads(l) for l in open(f"{work}/{name}.jsonl")]
for name, text, number in (("loki", lambda r: r["msg"], lambda r: r["n"]), ("es", lambda r: r["message"], lambda r: r["rmj"]["n"])):
    got = rows(name)
    lines = [r for r in got if text(r).startswith("check line ")]
    assert len(lines) == 650, f"{name}: {len(lines)} lines, want 650"
    assert [number(r) for r in lines] == sorted(number(r) for r in lines), f"{name}: out of order"
    assert [text(r) for r in lines] == [f"check line {i}" for i in range(1, 651)], f"{name}: lines differ"
    assert text(got[-1]).startswith("run finished: done"), f"{name}: no closing entry, last is {text(got[-1])!r}"
    fields = lines[0].get("labels") or lines[0]["rmj"]
    assert fields["repo"] and fields["destination"] == "local", f"{name}: missing repo or destination, got {fields}"
print("sinks: ok")
PY
