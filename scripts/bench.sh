#!/bin/sh
# Measures dist/LiteNotch.app in fixed scenarios, each against its own
# budget, plus the bundle size.
#
#   idle        nothing happening (the main budget)
#   timer       countdown running: the closed notch redraws its digits once a second
#   music       a track playing: artwork and pulsing bars in the closed notch
#   panel       the panel open on Home
#   floating    the Floating notch style with a countdown running
#   glass       the panel open on Home, drawn with Liquid Glass (macOS 26)
#
# Memory is the physical footprint, the figure Activity Monitor shows as
# "Memory"; RSS is printed for reference only (it counts shared framework
# pages). CPU is measured after the app has settled. Every scenario uses its
# own empty data directory, so the real app and its state are untouched.
#
# Usage: scripts/bench.sh [--check] [seconds] [scenario ...]
#   --check   exit 1 if any budget is exceeded
#   seconds   measuring window per scenario (default 20)
#   scenario  any of the above (default: all)
set -eu
cd "$(dirname "$0")/.."

MAX_BUNDLE_MB=15
SETTLE=8

CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
WINDOW=20
case "${1:-}" in ''|*[!0-9]*) ;; *) WINDOW=$1; shift ;; esac
SCENARIOS=${*:-"idle timer music panel floating glass"}

APP=dist/LiteNotch.app
[ -x "$APP/Contents/MacOS/LiteNotch" ] || { echo "build first: scripts/build-app.sh" >&2; exit 2; }

# The stand-in player for the music scenarios.
FAKE_DIR=$(mktemp -d /tmp/ln-bench-np.XXXXXX)
FAKE_LIB="$FAKE_DIR/libnowplaying-fake.dylib"
clang -dynamiclib -o "$FAKE_LIB" scripts/bench/nowplaying-fake.c

FAILED=0
PID=
DATA=
cleanup() {
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.3
        done
        if kill -0 "$PID" 2>/dev/null; then
            echo "LiteNotch did not quit on SIGTERM; killed" >&2
            kill -9 "$PID" 2>/dev/null || true
            FAILED=1
        fi
        PID=
    fi
    [ -z "$DATA" ] || rm -rf "$DATA"
    DATA=
}
trap 'cleanup; rm -rf "$FAKE_DIR"' EXIT

cpu_seconds() { # cumulative CPU time as [[hh:]mm:]ss.cc
    ps -o time= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}
footprint_mb() {
    vmmap --summary "$1" 2>/dev/null | awk '/^Physical footprint:/ {
        v = $3; unit = substr(v, length(v)); n = substr(v, 1, length(v) - 1)
        if (unit == "K") n = n / 1024; else if (unit == "G") n = n * 1024
        print n; exit }'
}

# scenario name, CPU budget %, memory budget MB, then settings JSON and env.
run() {
    name=$1 max_cpu=$2 max_mem=$3 settings=$4
    shift 4
    DATA=$(mktemp -d /tmp/ln-bench.XXXXXX)
    printf '{"settings":%s}' "$settings" > "$DATA/state.json"
    env LITENOTCH_DATA_DIR="$DATA" "$@" "$APP/Contents/MacOS/LiteNotch" >/dev/null 2>&1 &
    PID=$!
    sleep "$SETTLE"
    kill -0 "$PID" 2>/dev/null || { echo "$name: LiteNotch exited during startup" >&2; FAILED=1; PID=; return; }
    before=$(cpu_seconds "$PID")
    sleep "$WINDOW"
    after=$(cpu_seconds "$PID")
    mem=$(footprint_mb "$PID")
    rss=$(ps -o rss= -p "$PID" | tr -d ' ')
    [ -n "$mem" ] || { echo "$name: could not read the memory footprint (vmmap)" >&2; FAILED=1; }
    verdict=$(awk -v a="$before" -v b="$after" -v w="$WINDOW" -v mem="${mem:-0}" -v rss="$rss" \
        -v mc="$max_cpu" -v mm="$max_mem" -v name="$name" 'BEGIN {
        cpu = (b - a) / w * 100
        ok = (cpu <= mc && mem <= mm) ? "ok" : "OVER"
        printf "%-11s cpu %5.2f %% (≤ %s)   memory %5.1f MB (≤ %s)   rss %5.1f MB   %s\n",
            name, cpu, mc, mem, mm, rss / 1024, ok
    }')
    echo "$verdict"
    case "$verdict" in *OVER) FAILED=1 ;; esac
    cleanup
}

QUIET='{}'
for s in $SCENARIOS; do
    case "$s" in
        idle) run idle 0.5 30 "$QUIET" ;;
        timer) run timer 1.0 30 "$QUIET" \
            LITENOTCH_BENCH_COMMANDS='[{"cmd":"timer_set","secs":3600},{"cmd":"timer_toggle"}]' ;;
        music) run music 1.0 30 "$QUIET" LITENOTCH_BENCH_NOWPLAYING_LIB="$FAKE_LIB" ;;
        panel) run panel 1.5 40 "$QUIET" LITENOTCH_BENCH_OPEN=1 ;;
        floating) run floating 1.0 30 '{"appearance":{"notch_style":"floating"}}' \
            LITENOTCH_BENCH_COMMANDS='[{"cmd":"timer_set","secs":3600},{"cmd":"timer_toggle"}]' ;;
        glass) run glass 1.5 40 '{"appearance":{"material":"glass"}}' LITENOTCH_BENCH_OPEN=1 ;;
        *) echo "unknown scenario: $s" >&2; exit 2 ;;
    esac
done

BUNDLE_MB=$(du -sk "$APP" | awk '{printf "%.1f", $1 / 1024}')
if awk -v b="$BUNDLE_MB" -v m="$MAX_BUNDLE_MB" 'BEGIN { exit !(b > m) }'; then
    echo "app bundle  $BUNDLE_MB MB (≤ $MAX_BUNDLE_MB)   OVER"; FAILED=1
else
    echo "app bundle  $BUNDLE_MB MB (≤ $MAX_BUNDLE_MB)   ok"
fi

if [ "$FAILED" = 1 ]; then
    echo "OVER BUDGET"
    [ "$CHECK" = 0 ] || exit 1
fi
