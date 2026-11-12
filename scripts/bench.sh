#!/bin/sh
# Measures the idle footprint of dist/LiteNotch.app against the budget:
# memory, CPU while idle, and bundle size.
#
# Memory is the physical footprint, the figure Activity Monitor shows as
# "Memory". RSS is printed for reference only: it also counts system
# framework pages shared with every other app.
# Usage: scripts/bench.sh [--check] [seconds]
#   --check  exit 1 if a budget is exceeded
set -eu
cd "$(dirname "$0")/.."

MAX_MEM_MB=30
MAX_CPU_PCT=0.5
MAX_BUNDLE_MB=15

CHECK=0
if [ "${1:-}" = "--check" ]; then
    CHECK=1
    shift
fi
SECONDS_IDLE=${1:-30}
APP=dist/LiteNotch.app
[ -x "$APP/Contents/MacOS/LiteNotch" ] || { echo "build first: scripts/build-app.sh" >&2; exit 2; }

# A private data directory, so a LiteNotch the user is already running and
# their saved state are left alone.
DATA=$(mktemp -d /tmp/ln-bench.XXXXXX)
LITENOTCH_DATA_DIR="$DATA" "$APP/Contents/MacOS/LiteNotch" >/dev/null 2>&1 &
PID=$!
# Wait for the app to be gone before removing its data directory, and never
# leave a copy behind: a leftover window sits on the notch.
cleanup() {
    kill "$PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.3
    done
    if kill -0 "$PID" 2>/dev/null; then
        echo "LiteNotch did not quit on SIGTERM; killed" >&2
        kill -9 "$PID" 2>/dev/null || true
        QUIT_FAILED=1
    fi
    rm -rf "$DATA"
    [ -z "${QUIT_FAILED:-}" ] || exit 1
}
trap cleanup EXIT

sleep 5 # let launch work settle
kill -0 "$PID" 2>/dev/null || { echo "LiteNotch exited during startup" >&2; exit 2; }

cpu_seconds() {
    # ps prints cumulative CPU time as [[hh:]mm:]ss.cc
    ps -o time= -p "$PID" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}

CPU_BEFORE=$(cpu_seconds)
sleep "$SECONDS_IDLE"
CPU_AFTER=$(cpu_seconds)
RSS_KB=$(ps -o rss= -p "$PID" | tr -d ' ')
# vmmap prints e.g. "Physical footprint:         16.1M"
MEM_MB=$(vmmap --summary "$PID" 2>/dev/null | awk '/^Physical footprint:/ {
    v = $3; unit = substr(v, length(v)); n = substr(v, 1, length(v) - 1)
    if (unit == "K") n = n / 1024; else if (unit == "G") n = n * 1024
    print n; exit }')
[ -n "$MEM_MB" ] || { echo "could not read the memory footprint (vmmap)" >&2; exit 2; }
BUNDLE_KB=$(du -sk "$APP" | awk '{print $1}')

awk -v rss="$RSS_KB" -v mem="$MEM_MB" -v a="$CPU_BEFORE" -v b="$CPU_AFTER" -v secs="$SECONDS_IDLE" \
    -v bundle="$BUNDLE_KB" -v max_mem="$MAX_MEM_MB" -v max_cpu="$MAX_CPU_PCT" \
    -v max_bundle="$MAX_BUNDLE_MB" -v check="$CHECK" 'BEGIN {
    rss_mb = rss / 1024; cpu = (b - a) / secs * 100; bundle_mb = bundle / 1024
    printf "idle memory         %6.1f MB   budget %d MB\n", mem, max_mem
    printf "  (RSS, incl. shared %5.1f MB)\n", rss_mb
    printf "idle CPU over %2ds   %6.2f %%    budget %.1f %%\n", secs, cpu, max_cpu
    printf "app bundle          %6.1f MB   budget %d MB\n", bundle_mb, max_bundle
    over = (mem > max_mem) || (cpu > max_cpu) || (bundle_mb > max_bundle)
    if (over) print "OVER BUDGET"
    exit (check && over) ? 1 : 0
}'
