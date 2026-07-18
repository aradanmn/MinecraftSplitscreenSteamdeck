#!/bin/bash
# =============================================================================
# Benchmark summarizer — sampler.csv + events.csv → per-segment stats.
# =============================================================================
# Companion to tests/benchmark/sampler.sh (CSV schema defined there).
#
# Usage:
#   summarize.sh <cycle-dir>                      per-segment stats (stdout +
#                                                 <cycle-dir>/summary.txt)
#   summarize.sh <cycle-dir> --compare <other>    A-vs-B delta table (markdown),
#                                                 <other> = same-N cycle dir of
#                                                 the other phase
#   summarize.sh <cycle-dir> --mangohud-dir <dir> where MangoHud frametime CSVs
#                                                 live (default
#                                                 ~/mcss-benchmark/mangohud);
#                                                 files whose mtime falls inside
#                                                 the cycle's sample window are
#                                                 reported (p50 / 1%-low FPS)
#
# Segments are the intervals between consecutive events.csv marks (a mark
# labels the segment it STARTS; the last mark runs to the end of sampling).
# Rows before the first mark are ignored — mark `settle` first.
#
# Output is `key=value` tokens per segment line so the compare mode (and any
# hand analysis) can parse it with awk. All deltas are computed row-to-row
# from raw counters, so a lost tick skews nothing.
# =============================================================================
set -euo pipefail

usage() {
    sed -n '2,24p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
    exit 2
}

CYCLE_DIR="${1:-}"
[[ -n "$CYCLE_DIR" && -d "$CYCLE_DIR" ]] || usage
shift

COMPARE_DIR=""
MANGOHUD_DIR="$HOME/mcss-benchmark/mangohud"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --compare)      COMPARE_DIR="${2:?--compare requires a dir}"; shift 2 ;;
        --mangohud-dir) MANGOHUD_DIR="${2:?--mangohud-dir requires a dir}"; shift 2 ;;
        *) usage ;;
    esac
done

# ── Per-segment stats for one cycle dir → key=value lines ────────────────────
_summarize_one() {
    local dir="$1"
    local csv="$dir/sampler.csv"
    local events="$dir/events.csv"
    [[ -s "$csv" ]] || { echo "[summarize] missing/empty $csv" >&2; return 1; }
    [[ -s "$events" ]] || { echo "[summarize] missing/empty $events (no marks — nothing to score)" >&2; return 1; }

    awk -F, -v events="$events" '
    BEGIN {
        nseg = 0
        while ((getline line < events) > 0) {
            split(line, a, ",")
            if (a[1] + 0 > 0) { seg_start[nseg] = a[1] + 0; seg_name[nseg] = a[2]; nseg++ }
        }
        close(events)
    }
    NR == 1 { next }                                  # header
    {
        ts = $1 + 0
        # Which segment does this row fall in? (marks sorted by construction)
        seg = -1
        for (i = 0; i < nseg; i++) if (ts >= seg_start[i]) seg = i
        if (seg < 0) next                             # before first mark

        n[seg]++
        if (!(seg in first_ts)) first_ts[seg] = ts
        last_ts[seg] = ts

        # System CPU% from jiffy deltas vs previous row (global prev, so the
        # first row of a segment deltas against the last row of the previous
        # one — a 1-tick boundary blur, acceptable at 2s cadence)
        if (prev_total > 0 && $2 > prev_total) {
            dt_j = $2 - prev_total
            didle = $3 - prev_idle
            cpu = 100 * (1 - didle / dt_j)
            if (cpu >= 0 && cpu <= 100) {
                cpu_sum[seg] += cpu; cpu_n[seg]++
                if (cpu > cpu_max[seg]) cpu_max[seg] = cpu
            }
        }
        prev_total = $2; prev_idle = $3

        if ($6 != "")  { ma = $6 + 0; if (!(seg in ma_min) || ma < ma_min[seg]) ma_min[seg] = ma }
        if ($7 != "" && $8 != "") {
            su = $7 - $8                              # swap used kb
            if (!(seg in swap_first)) swap_first[seg] = su
            swap_last[seg] = su
        }
        if ($11 != "") { p = $11 + 0; if (p > psi_max[seg]) psi_max[seg] = p }
        if ($13 != "") { g = $13 + 0; gpu_sum[seg] += g; gpu_n[seg]++ }
        if ($15 != "") { t = $15 + 0; if (t > temp_max[seg]) temp_max[seg] = t }
        clk = ($16 != "") ? $16 + 0 : 100

        # Per-slot: cols 17.. are 7-wide blocks: pid,utime,stime,rss,threads,rd,wr
        rss_sum = 0
        for (s = 1; s <= 4; s++) {
            base = 16 + (s - 1) * 7
            pid = $(base + 1); ut = $(base + 2); st = $(base + 3); rss = $(base + 4)
            rd = $(base + 6); wr = $(base + 7)
            if (pid == "") continue
            if (rss != "") {
                r = rss + 0
                rss_sum += r
                if (r > slot_rss_max[seg, s]) slot_rss_max[seg, s] = r
                slot_seen[seg, s] = 1
            }
            key = seg SUBSEP s
            cpuj = ut + st
            if ((key in slot_prev_cpu) && slot_prev_pid[key] == pid && (key in slot_prev_ts)) {
                dts = ts - slot_prev_ts[key]
                if (dts > 0 && cpuj >= slot_prev_cpu[key]) {
                    sc = 100 * (cpuj - slot_prev_cpu[key]) / clk / dts
                    slot_cpu_sum[key] += sc; slot_cpu_n[key]++
                }
            }
            if (!(key in slot_first_rd) && rd != "") { slot_first_rd[key] = rd + 0; slot_first_wr[key] = wr + 0 }
            if (rd != "") { slot_last_rd[key] = rd + 0; slot_last_wr[key] = wr + 0 }
            slot_prev_cpu[key] = cpuj; slot_prev_pid[key] = pid; slot_prev_ts[key] = ts
        }
        if (rss_sum > rss_sum_max[seg]) rss_sum_max[seg] = rss_sum
    }
    END {
        for (i = 0; i < nseg; i++) {
            if (n[i] == 0) continue
            dur = last_ts[i] - first_ts[i]
            line = sprintf("segment=%s samples=%d duration_s=%d", seg_name[i], n[i], dur)
            line = line sprintf(" cpu_mean_pct=%.1f cpu_max_pct=%.1f", \
                (cpu_n[i] ? cpu_sum[i] / cpu_n[i] : 0), cpu_max[i] + 0)
            line = line sprintf(" gpu_mean_pct=%.1f", (gpu_n[i] ? gpu_sum[i] / gpu_n[i] : 0))
            line = line sprintf(" memavail_min_mb=%.0f", (i in ma_min ? ma_min[i] / 1024 : 0))
            line = line sprintf(" swap_delta_mb=%.0f", \
                ((i in swap_first) ? (swap_last[i] - swap_first[i]) / 1024 : 0))
            line = line sprintf(" psi_mem_full_max=%.2f", psi_max[i] + 0)
            line = line sprintf(" apu_temp_max_c=%.1f", temp_max[i] / 1000)
            line = line sprintf(" rss_sum_max_mb=%.0f", rss_sum_max[i] / 1024)
            for (s = 1; s <= 4; s++) {
                if (!((i, s) in slot_seen)) continue
                key = i SUBSEP s
                line = line sprintf(" s%d_cpu_pct=%.1f s%d_rss_max_mb=%.0f", \
                    s, (slot_cpu_n[key] ? slot_cpu_sum[key] / slot_cpu_n[key] : 0), \
                    s, slot_rss_max[i, s] / 1024)
                if (key in slot_first_rd) {
                    line = line sprintf(" s%d_io_rd_mb=%.0f s%d_io_wr_mb=%.0f", \
                        s, (slot_last_rd[key] - slot_first_rd[key]) / 1048576, \
                        s, (slot_last_wr[key] - slot_first_wr[key]) / 1048576)
                }
            }
            print line
        }
    }' "$csv"
}

# ── MangoHud logs whose mtime falls inside the sample window ─────────────────
_mangohud_stats() {
    local dir="$1"
    local csv="$dir/sampler.csv"
    [[ -d "$MANGOHUD_DIR" && -s "$csv" ]] || return 0
    local t0 t1
    t0=$(awk -F, 'NR==2{print $1; exit}' "$csv")
    t1=$(awk -F, 'END{print $1}' "$csv")
    [[ "$t0" =~ ^[0-9]+$ && "$t1" =~ ^[0-9]+$ ]] || return 0

    local f mt
    for f in "$MANGOHUD_DIR"/*.csv; do
        [[ -f "$f" ]] || continue
        mt=$(stat -c %Y "$f" 2>/dev/null) || continue
        # A log's mtime is its LAST write — inside or shortly after the window
        (( mt >= t0 && mt <= t1 + 300 )) || continue
        # MangoHud logs: metadata line(s), then a header row containing "fps",
        # then numeric rows. Locate the fps column dynamically.
        awk -F, -v fname="$(basename "$f")" '
            hdr == 0 {
                for (i = 1; i <= NF; i++) if ($i == "fps") { col = i; hdr = 1 }
                next
            }
            hdr == 1 && $col + 0 > 0 { v[n++] = $col + 0 }
            END {
                if (n < 10) exit                       # too short to score
                # insertion sort (n is small: ~10 samples/s * segment)
                for (i = 1; i < n; i++) {
                    x = v[i]; j = i - 1
                    while (j >= 0 && v[j] > x) { v[j+1] = v[j]; j-- }
                    v[j+1] = x
                }
                p50 = v[int(n * 0.50)]
                p1  = v[int(n * 0.01)]
                printf "mangohud file=%s samples=%d fps_p50=%.1f fps_1pct_low=%.1f\n", fname, n, p50, p1
            }' "$f"
    done
}

# ── Compare mode: markdown delta table over shared segments ──────────────────
_compare() {
    local a="$1" b="$2"
    local sa sb
    sa=$(_summarize_one "$a")
    sb=$(_summarize_one "$b")

    echo ""
    echo "| segment | metric | A ($(basename "$a")) | B ($(basename "$b")) | Δ (B−A) |"
    echo "|---|---|---|---|---|"
    local metrics="cpu_mean_pct gpu_mean_pct memavail_min_mb swap_delta_mb psi_mem_full_max apu_temp_max_c rss_sum_max_mb s1_cpu_pct s1_rss_max_mb s2_rss_max_mb s3_rss_max_mb s4_rss_max_mb"
    local seg m va vb
    for seg in $(awk '{for(i=1;i<=NF;i++) if($i ~ /^segment=/){sub(/^segment=/,"",$i); print $i}}' <<< "$sa"); do
        for m in $metrics; do
            va=$(awk -v s="segment=$seg" -v k="$m" '$1==s {for(i=1;i<=NF;i++) if($i ~ "^"k"=") {sub("^"k"=","",$i); print $i}}' <<< "$sa")
            vb=$(awk -v s="segment=$seg" -v k="$m" '$1==s {for(i=1;i<=NF;i++) if($i ~ "^"k"=") {sub("^"k"=","",$i); print $i}}' <<< "$sb")
            [[ -n "$va" || -n "$vb" ]] || continue
            local delta=""
            if [[ -n "$va" && -n "$vb" ]]; then
                delta=$(awk -v a="$va" -v b="$vb" 'BEGIN{printf "%+.1f", b-a}')
            fi
            echo "| $seg | $m | ${va:-—} | ${vb:-—} | ${delta:-—} |"
        done
    done
    echo ""
    echo "MangoHud (A):"; _mangohud_stats "$a" | sed 's/^/  /'
    echo "MangoHud (B):"; _mangohud_stats "$b" | sed 's/^/  /'
}

if [[ -n "$COMPARE_DIR" ]]; then
    [[ -d "$COMPARE_DIR" ]] || { echo "[summarize] compare dir not found: $COMPARE_DIR" >&2; exit 1; }
    _compare "$CYCLE_DIR" "$COMPARE_DIR"
else
    {
        _summarize_one "$CYCLE_DIR"
        _mangohud_stats "$CYCLE_DIR"
    } | tee "$CYCLE_DIR/summary.txt"
fi
