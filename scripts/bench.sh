#!/bin/sh
# Measures dist/LiteNotch.app in fixed scenarios, each against its own
# budget, plus the bundle size.
#
#   idle        nothing happening (the main budget)
#   timer       countdown running: the closed notch redraws its digits once a second
#   music       a track playing: artwork and pulsing bars in the closed notch
#   panel       the panel open on Home
#   island      the Island notch style with a countdown running
#   glass       the panel open on Home, drawn with Liquid Glass (macOS 26)
#   glassisland the panel open on Home in the Island style, drawn with
#               Liquid Glass (macOS 26)
#   calendar    an event about to start: the closed notch counts down to it
#   pair        two countdowns side by side in the closed notch
#   body        the panel open on Home showing the water and stretch
#               gauges (their wave is a Core Animation loop)
#   bodyclosed  the closed notch showing a water gauge (redrawn once per
#               percent)
#   closedglass the closed notch drawn with Liquid Glass (Island, Match
#               theme, light) with a countdown running; on a display with a
#               notch it is drawn black, so measure it on one without
#
# Memory is the physical footprint, the figure Activity Monitor shows as
# "Memory"; RSS is printed for reference only (it counts shared framework
# pages). CPU is measured after the app has settled. Every scenario uses its
# own empty data directory, so the real app and its state are untouched.
#
# The scenarios run side by side by default: each is its own process and
# CPU is that process's own time, so a whole run takes one settle plus one
# window (about 30 s) instead of that per scenario. --serial runs them one
# after another, for when a result looks disturbed by the others.
#
# Usage: scripts/bench.sh [--check] [--serial] [seconds] [scenario ...]
#   --check   exit 1 if any budget is exceeded
#   --serial  one scenario at a time
#   seconds   measuring window per scenario (default 20)
#   scenario  any of the above (default: all)
set -eu
cd "$(dirname "$0")/.."

MAX_BUNDLE_MB=15
SETTLE=8

CHECK=0
SERIAL=0
while :; do
    case "${1:-}" in
        --check) CHECK=1; shift ;;
        --serial) SERIAL=1; shift ;;
        *) break ;;
    esac
done
WINDOW=20
case "${1:-}" in ''|*[!0-9]*) ;; *) WINDOW=$1; shift ;; esac
ALL="idle timer music panel island glass glassisland calendar pair body bodyclosed closedglass"
SCENARIOS=${*:-$ALL}

APP=dist/LiteNotch.app
[ -x "$APP/Contents/MacOS/LiteNotch" ] || { echo "build first: scripts/build-app.sh" >&2; exit 2; }

# Everything temporary lives here: the stand-in player and one data
# directory per scenario. Kept short: the socket path inside must fit in
# sun_path (104 bytes).
WORK=$(mktemp -d /tmp/ln-bench.XXXXXX)

# The stand-in player for the music scenarios.
FAKE_LIB="$WORK/libnowplaying-fake.dylib"
clang -dynamiclib -o "$FAKE_LIB" scripts/bench/nowplaying-fake.c

FAILED=0
# One line per running scenario: name pid cpu-budget memory-budget cpu-before
RUNNING="$WORK/running"
: > "$RUNNING"

stop_all() {
    while read -r name pid _; do
        kill "$pid" 2>/dev/null || true
    done < "$RUNNING"
    while read -r name pid _; do
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.3
        done
        if kill -0 "$pid" 2>/dev/null; then
            echo "$name: LiteNotch did not quit on SIGTERM; killed" >&2
            kill -9 "$pid" 2>/dev/null || true
            FAILED=1
        fi
    done < "$RUNNING"
    : > "$RUNNING"
}
trap 'stop_all; rm -rf "$WORK"' EXIT

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
start() {
    name=$1 max_cpu=$2 max_mem=$3 settings=$4
    shift 4
    data="$WORK/$name"
    rm -rf "$data"
    mkdir "$data"
    printf '{"settings":%s}' "$settings" > "$data/state.json"
    env LITENOTCH_DATA_DIR="$data" "$@" "$APP/Contents/MacOS/LiteNotch" >/dev/null 2>&1 &
    echo "$name $! $max_cpu $max_mem" >> "$RUNNING"
}

# Settles, then measures every running scenario over the same window.
# With RECHECK set, a scenario over budget is only noted in $WORK/over, to
# be measured again alone, rather than failing the run.
RECHECK=0
measure() {
    [ -s "$RUNNING" ] || return 0
    sleep "$SETTLE"
    before="$WORK/before"
    : > "$before"
    while read -r name pid max_cpu max_mem; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "$name $pid $max_cpu $max_mem $(cpu_seconds "$pid")" >> "$before"
        else
            echo "$name: LiteNotch exited during startup" >&2; FAILED=1
        fi
    done < "$RUNNING"
    sleep "$WINDOW"
    while read -r name pid max_cpu max_mem cpu_before; do
        after=$(cpu_seconds "$pid")
        if [ -z "$after" ]; then
            echo "$name: LiteNotch exited while measured" >&2; FAILED=1; continue
        fi
        mem=$(footprint_mb "$pid")
        rss=$(ps -o rss= -p "$pid" | tr -d ' ')
        [ -n "$mem" ] || { echo "$name: could not read the memory footprint (vmmap)" >&2; FAILED=1; }
        verdict=$(awk -v a="$cpu_before" -v b="$after" -v w="$WINDOW" -v mem="${mem:-0}" -v rss="$rss" \
            -v mc="$max_cpu" -v mm="$max_mem" -v name="$name" 'BEGIN {
            cpu = (b - a) / w * 100
            ok = (cpu <= mc && mem <= mm) ? "ok" : "OVER"
            printf "%-11s cpu %5.2f %% (≤ %s)   memory %5.1f MB (≤ %s)   rss %5.1f MB   %s\n",
                name, cpu, mc, mem, mm, rss / 1024, ok
        }')
        case "$verdict" in
            *OVER)
                if [ "$RECHECK" = 1 ]; then
                    echo "$verdict (with others running; measuring again alone)"
                    echo "$name" >> "$WORK/over"
                else
                    echo "$verdict"; FAILED=1
                fi ;;
            *) echo "$verdict" ;;
        esac
    done < "$before"
    stop_all
}

TIMER='[{"cmd":"timer_set","secs":3600},{"cmd":"timer_toggle"}]'
QUIET='{}'
launch() {
    case "$1" in
        idle) start idle 0.5 30 "$QUIET" ;;
        timer) start timer 1.0 30 "$QUIET" LITENOTCH_BENCH_COMMANDS="$TIMER" ;;
        music) start music 1.0 30 "$QUIET" LITENOTCH_BENCH_NOWPLAYING_LIB="$FAKE_LIB" ;;
        panel) start panel 1.5 40 "$QUIET" LITENOTCH_BENCH_OPEN=1 ;;
        island) start island 1.0 30 '{"appearance":{"notch_style":"island"}}' \
            LITENOTCH_BENCH_COMMANDS="$TIMER" ;;
        glass) start glass 1.5 40 '{"appearance":{"material":"glass"}}' LITENOTCH_BENCH_OPEN=1 ;;
        glassisland) start glassisland 1.5 40 '{"appearance":{"notch_style":"island","material":"glass"}}' \
            LITENOTCH_BENCH_OPEN=1 ;;
        calendar)
            # An event 50 minutes away with a 60-minute reminder, so the
            # countdown shows for the whole window. The real calendar is not
            # read in a benchmark run (see `Bench` in main.swift).
            begin=$(( ($(date +%s) + 3000) * 1000 ))
            start calendar 1.0 30 '{"calendar":{"enabled":true,"alert_minutes":60}}' \
                LITENOTCH_BENCH_COMMANDS="[{\"cmd\":\"calendar_events\",\"events\":[{\"id\":\"bench\",\"title\":\"Review\",\"start_ms\":$begin,\"end_ms\":$((begin + 1800000))}]},{\"cmd\":\"notify_dismiss_banner\"}]" ;;
        pair) start pair 1.0 30 "$QUIET" \
            LITENOTCH_BENCH_COMMANDS='[{"cmd":"timer_set","secs":3600},{"cmd":"timer_toggle"},{"cmd":"pomodoro_toggle"}]' ;;
        body) start body 1.5 40 '{"body":{"water_mins":60,"stretch_mins":45},"day":{"home_card":"body"}}' \
            LITENOTCH_BENCH_OPEN=1 LITENOTCH_BENCH_COMMANDS='[{"cmd":"body_drink"},{"cmd":"body_stretch"}]' ;;
        bodyclosed) start bodyclosed 1.0 30 '{"body":{"water_mins":90}}' ;;
        closedglass) start closedglass 1.0 30 '{"appearance":{"notch_style":"island","closed_notch":"theme","theme":"light","material":"glass"}}' \
            LITENOTCH_BENCH_COMMANDS="$TIMER" ;;
    esac
}

# Every name is checked before anything starts.
for s in $SCENARIOS; do
    case " $ALL " in *" $s "*) ;; *) echo "unknown scenario: $s" >&2; exit 2 ;; esac
done

if [ "$SERIAL" = 1 ]; then
    for s in $SCENARIOS; do launch "$s"; measure; done
else
    # All together; whatever comes out over budget is measured again
    # alone, and only that result counts, so the others cannot fail a run.
    RECHECK=1
    : > "$WORK/over"
    for s in $SCENARIOS; do launch "$s"; done
    measure
    RECHECK=0
    for s in $(cat "$WORK/over"); do launch "$s"; measure; done
fi

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
