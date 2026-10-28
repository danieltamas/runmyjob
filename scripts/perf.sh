#!/usr/bin/env bash
# CPU cost of the running RMJ app (docs/PLAN.md, "Measured by" step 4): under 0.3 percent of one core over the idle
# window with no job running, under 2 percent while one job streams output. Run it with the panel closed.
#   perf.sh [idle-seconds]   (default 600; the streaming window is 60 s)
set -euo pipefail

# CPU time of the app plus the children it has finished with, from the kernel's resource usage: a ps snapshot
# would miss a child that starts and exits between two readings.
cpu_seconds() {
  python3 -I - "$1" <<'PY'
import ctypes, struct, sys
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class Timebase(ctypes.Structure): _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
base = Timebase(); libc.mach_timebase_info(ctypes.byref(base))
buffer = ctypes.create_string_buffer(512)
if libc.proc_pid_rusage(int(sys.argv[1]), 2, buffer) != 0: sys.exit(1)
fields = struct.unpack_from("<12Q", buffer.raw, 16)  # RUSAGE_INFO_V2 after the 16-byte uuid
print("%.3f" % ((fields[0] + fields[1] + fields[10] + fields[11]) * base.numer / base.denom / 1e9))
PY
}

# Average CPU percent of $1 over $2 seconds.
average() {
  local before after
  before=$(cpu_seconds "$1")
  sleep "$2"
  after=$(cpu_seconds "$1") || { echo "perf: RMJ exited" >&2; exit 2; }
  awk -v a="$after" -v b="$before" -v s="$2" 'BEGIN { printf "%.2f", (a - b) / s * 100 }'
}

idle=${1:-600}
pid=$(pgrep -x RMJ | head -n 1 || true)
[[ -n $pid ]] || { echo "perf: RMJ is not running" >&2; exit 2; }
rmj=${RMJ_CLI:-$HOME/.local/bin/rmj}
[[ -x $rmj ]] || { echo "perf: $rmj is missing" >&2; exit 2; }

quiet=$(average "$pid" "$idle")
echo "perf: idle $quiet% over ${idle}s (budget 0.3%)"

# One job printing ten lines a second for the whole window, run on this Mac so no box is needed.
"$rmj" run -- sh -c 'i=0; while [ $i -lt 650 ]; do echo "line $i"; i=$((i+1)); sleep 0.1; done' >/dev/null 2>&1 &
job=$!
sleep 3
streaming=$(average "$pid" 60)
wait "$job" 2>/dev/null || true  # the job ends on its own: killing the client would orphan its ledger row
echo "perf: streaming $streaming% over 60s (budget 2%)"

awk -v q="$quiet" -v s="$streaming" 'BEGIN { exit (q < 0.3 && s < 2.0) ? 0 : 1 }' || { echo "perf: over budget" >&2; exit 1; }
