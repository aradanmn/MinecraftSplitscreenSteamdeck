#!/bin/bash
# =============================================================================
# Benchmark metrics sampler — pure /proc + /sys, no packages beyond jq.
# =============================================================================
# Companion to tests/benchmark/RUNBOOK.md (A/B benchmark of the standard mod
# set + JVM flags). Samples system + per-slot metrics on a fixed cadence and
# appends one wide CSV row per tick. Raw cumulative counters are recorded
# as-is; summarize.sh computes deltas/rates so a dropped tick never corrupts
# derived values.
#
# Usage:
#   sampler.sh run  <outdir>          start sampling loop (blocks; run in
#                                     background), writes <outdir>/sampler.csv
#                                     and <outdir>/sampler.pid
#   sampler.sh mark <outdir> <label>  append "epoch,label" to <outdir>/events.csv
#                                     (segment boundaries: S1_idle, S2_flight…)
#   sampler.sh stop <outdir>          TERM the loop via the pidfile and wait
#
# Env:
#   BENCH_SAMPLE_INTERVAL_S  poll cadence, seconds (default 2)
#   SPLITSCREEN_STATE        state file (default ~/.local/share/PolyMC/
#                            splitscreen_state.json)
#
# Slot→PID discovery per tick, in order:
#   1. state file .slots["N"].pid (schema of instance_lifecycle.sh
#      get_java_pid — self-contained here because the baseline install's
#      modules may predate the current accessors)
#   2. fallback: scan /proc/*/cmdline for "instances/latestUpdate-N" (matches
#      the -l instance argument PolyMC passes through to java)
#
# Loop skeleton pairs with modules/watchdog.sh: env-tunable interval,
# `trap 'exit 0' TERM INT`, while-true sleep. Every filesystem probe is
# tolerant — a missing node yields an empty CSV field, never a crash.
# =============================================================================
set -euo pipefail

STATE_FILE="${SPLITSCREEN_STATE:-$HOME/.local/share/PolyMC/splitscreen_state.json}"
INTERVAL="${BENCH_SAMPLE_INTERVAL_S:-2}"

_rd() { cat "$1" 2>/dev/null || true; }

usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
    exit 2
}

# ── One-time hardware probes (tolerant: absent path → empty var) ─────────────
GPU_DEV_DIR=""
HWMON_TEMP=""
CLK_TCK=100
_probe_hardware() {
    local d
    for d in /sys/class/drm/card*/device; do
        if [[ -r "$d/gpu_busy_percent" ]]; then
            GPU_DEV_DIR="$d"
            break
        fi
    done
    local h
    for h in /sys/class/hwmon/hwmon*; do
        if [[ "$(_rd "$h/name")" == "amdgpu" && -r "$h/temp1_input" ]]; then
            HWMON_TEMP="$h/temp1_input"
            break
        fi
    done
    CLK_TCK=$(getconf CLK_TCK 2>/dev/null) || CLK_TCK=100
}

# ── Per-slot java PID ────────────────────────────────────────────────────────
# Echoes the PID or empty. $1 = slot 1-4.
_slot_pid() {
    local slot="$1" pid=""
    if [[ -r "$STATE_FILE" ]]; then
        pid=$(jq -r --arg s "$slot" \
            'if .slots[$s].active == true then (.slots[$s].pid // empty) else empty end' \
            "$STATE_FILE" 2>/dev/null) || pid=""
    fi
    # Validate: state may hold a stale/null pid, or predate this schema
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ ! -d "/proc/$pid" ]]; then
        pid=""
    fi
    if [[ -z "$pid" ]]; then
        # Fallback: java processes carry "…instances/latestUpdate-N…" in cmdline.
        # tr NULs to \n so the match can't jump argument boundaries.
        local p
        for p in $(pgrep -f "latestUpdate-${slot}" 2>/dev/null || true); do
            if tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null \
                    | grep -q "instances/latestUpdate-${slot}\(/\|$\)"; then
                # Prefer the actual java process over PolyMC/bwrap wrappers
                if grep -qi 'java' "/proc/$p/comm" 2>/dev/null; then
                    pid="$p"
                    break
                fi
                [[ -z "$pid" ]] && pid="$p"
            fi
        done
    fi
    printf '%s' "$pid"
}

# ── Per-PID columns: pid,utime,stime,rss_kb,threads,read_b,write_b ───────────
_pid_columns() {
    local pid="$1"
    if [[ -z "$pid" || ! -d "/proc/$pid" ]]; then
        printf ',,,,,,'
        return 0
    fi
    # /proc/<pid>/stat: comm may contain spaces/parens — parse after the LAST ')'.
    local stat rest utime="" stime=""
    stat=$(_rd "/proc/$pid/stat")
    rest="${stat##*) }"
    read -r _ _ _ _ _ _ _ _ _ _ _ utime stime _ <<< "$rest" || true
    local rss_kb threads
    rss_kb=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null) || rss_kb=""
    threads=$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null) || threads=""
    local read_b write_b
    read_b=$(awk '/^read_bytes:/{print $2}' "/proc/$pid/io" 2>/dev/null) || read_b=""
    write_b=$(awk '/^write_bytes:/{print $2}' "/proc/$pid/io" 2>/dev/null) || write_b=""
    printf '%s,%s,%s,%s,%s,%s,%s' "$pid" "$utime" "$stime" "$rss_kb" "$threads" "$read_b" "$write_b"
}

# ── PSI "some avg10" (or full for $2=full) from /proc/pressure/<res> ─────────
_psi_avg10() {
    local res="$1" kind="${2:-some}"
    awk -v k="$kind" '$1 == k {sub(/^avg10=/, "", $2); print $2}' \
        "/proc/pressure/$res" 2>/dev/null || true
}

_csv_header() {
    local h="ts_epoch,cpu_jiffies_total,cpu_jiffies_idle,cpu_jiffies_iowait"
    h+=",mem_total_kb,mem_avail_kb,swap_total_kb,swap_free_kb"
    h+=",psi_cpu_some_avg10,psi_mem_some_avg10,psi_mem_full_avg10,psi_io_some_avg10"
    h+=",gpu_busy_pct,vram_used_b,apu_temp_mc,clk_tck"
    local s
    for s in 1 2 3 4; do
        h+=",s${s}_pid,s${s}_utime,s${s}_stime,s${s}_rss_kb,s${s}_threads,s${s}_read_b,s${s}_write_b"
    done
    printf '%s\n' "$h"
}

_sample_row() {
    local ts
    ts=$(date +%s)

    # /proc/stat line 1: cpu user nice system idle iowait irq softirq steal …
    local cpu_total="" cpu_idle="" cpu_iowait=""
    read -r cpu_total cpu_idle cpu_iowait < <(
        awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5, $6; exit}' /proc/stat 2>/dev/null
    ) || true

    local mem_total mem_avail swap_total swap_free
    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null) || mem_total=""
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null) || mem_avail=""
    swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null) || swap_total=""
    swap_free=$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null) || swap_free=""

    local psi_cpu psi_mem_some psi_mem_full psi_io
    psi_cpu=$(_psi_avg10 cpu some)
    psi_mem_some=$(_psi_avg10 memory some)
    psi_mem_full=$(_psi_avg10 memory full)
    psi_io=$(_psi_avg10 io some)

    local gpu_busy="" vram_used=""
    if [[ -n "$GPU_DEV_DIR" ]]; then
        gpu_busy=$(_rd "$GPU_DEV_DIR/gpu_busy_percent")
        vram_used=$(_rd "$GPU_DEV_DIR/mem_info_vram_used")
    fi
    local apu_temp=""
    [[ -n "$HWMON_TEMP" ]] && apu_temp=$(_rd "$HWMON_TEMP")

    local row="${ts},${cpu_total},${cpu_idle},${cpu_iowait}"
    row+=",${mem_total},${mem_avail},${swap_total},${swap_free}"
    row+=",${psi_cpu},${psi_mem_some},${psi_mem_full},${psi_io}"
    row+=",${gpu_busy},${vram_used},${apu_temp},${CLK_TCK}"
    local s pid
    for s in 1 2 3 4; do
        pid=$(_slot_pid "$s")
        row+=",$(_pid_columns "$pid")"
    done
    printf '%s\n' "$row"
}

cmd_run() {
    local outdir="$1"
    mkdir -p "$outdir"
    local csv="$outdir/sampler.csv"
    local pidfile="$outdir/sampler.pid"

    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
        echo "[sampler] already running (pid $(cat "$pidfile")) for $outdir" >&2
        exit 1
    fi

    _probe_hardware
    echo "[sampler] gpu=${GPU_DEV_DIR:-<none>} temp=${HWMON_TEMP:-<none>} interval=${INTERVAL}s → $csv" >&2

    [[ -s "$csv" ]] || _csv_header > "$csv"
    echo $$ > "$pidfile"
    trap 'rm -f "$pidfile"; exit 0' TERM INT EXIT

    while true; do
        _sample_row >> "$csv" || true
        sleep "$INTERVAL"
    done
}

cmd_mark() {
    local outdir="$1" label="$2"
    mkdir -p "$outdir"
    printf '%s,%s\n' "$(date +%s)" "$label" >> "$outdir/events.csv"
    echo "[sampler] mark: $label" >&2
}

cmd_stop() {
    local outdir="$1"
    local pidfile="$outdir/sampler.pid"
    if [[ ! -f "$pidfile" ]]; then
        echo "[sampler] no pidfile in $outdir — nothing to stop" >&2
        return 0
    fi
    local pid
    pid=$(cat "$pidfile" 2>/dev/null) || true
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        local i
        for i in $(seq 1 10); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
    echo "[sampler] stopped" >&2
}

case "${1:-}" in
    run)  [[ $# -eq 2 ]] || usage; cmd_run "$2" ;;
    mark) [[ $# -eq 3 ]] || usage; cmd_mark "$2" "$3" ;;
    stop) [[ $# -eq 2 ]] || usage; cmd_stop "$2" ;;
    *)    usage ;;
esac
