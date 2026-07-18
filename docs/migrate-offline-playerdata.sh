#!/bin/bash
# =============================================================================
# migrate-offline-playerdata.sh — carry offline-server player data across the
# P1-P4 → Player1-Player4 rename (#93 / PR #96)
# =============================================================================
# Offline-mode servers derive each player's UUID from the NAME
# (UUIDv3 of "OfflinePlayer:<name>"), so renaming the accounts mints brand-new
# identities: inventory, position, advancements, and stats stay behind under
# the old UUID. Run this ON THE SERVER HOST, with the server STOPPED, to move
# that data to the new UUIDs.
#
# Covers, per world folder (vanilla + Paper layouts):
#   playerdata/<uuid>.dat (+ .dat_old)   advancements/<uuid>.json
#   stats/<uuid>.json
# and rewrites matching entries in ops.json / whitelist.json next to the
# server jar. Plugin data keyed by UUID (Essentials etc.) is NOT handled.
#
# Usage:
#   migrate-offline-playerdata.sh <server-dir>            # dry run (default)
#   migrate-offline-playerdata.sh <server-dir> --apply
#
# <server-dir> is the folder holding server.properties. Every world folder
# named by a level-name-style directory containing playerdata/ is migrated
# (Paper splits world / world_nether / world_the_end — only the overworld
# holds playerdata). A timestamped tar backup of the touched files is written
# to <server-dir> before anything moves.
# =============================================================================
set -euo pipefail

SERVER_DIR="${1:?usage: $0 <server-dir> [--apply]}"
MODE="${2:-dry-run}"
cd "$SERVER_DIR"

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

# name pairs: old new (edit here if your prefix/count differ)
PAIRS="P1 Player1
P2 Player2
P3 Player3
P4 Player4"

offline_uuid() {
    python3 - "$1" <<'PY'
import sys, uuid, hashlib
d = bytearray(hashlib.md5(("OfflinePlayer:" + sys.argv[1]).encode()).digest())
d[6] = 0x30 | (d[6] & 0x0F)
d[8] = 0x80 | (d[8] & 0x3F)
print(uuid.UUID(bytes=bytes(d)))
PY
}

if pgrep -f "java.*$(basename "$PWD")" >/dev/null 2>&1; then
    echo "WARNING: a java process mentioning this directory is running." >&2
    echo "Stop the server before --apply;" \
         "data written after the copy is lost." >&2
fi

planned=()   # "src|dst" pairs
while read -r old new; do
    ou=$(offline_uuid "$old"); nu=$(offline_uuid "$new")
    echo "== $old ($ou) -> $new ($nu)"
    for pd in */playerdata; do
        w=${pd%/playerdata}
        for f in "$w/playerdata/$ou.dat" "$w/playerdata/$ou.dat_old" \
                 "$w/advancements/$ou.json" "$w/stats/$ou.json"; do
            [ -f "$f" ] || continue
            dst=${f//$ou/$nu}
            if [ -e "$dst" ]; then
                echo "   SKIP $f -> $dst"
                echo "        (destination exists — new name already" \
                     "played; delete it first if old data should win)"
                continue
            fi
            echo "   move $f -> $dst"
            planned+=("$f|$dst")
        done
    done
    # ops/whitelist: rewrite uuid+name in place
    for j in ops.json whitelist.json; do
        [ -f "$j" ] || continue
        if python3 -c "
import json,sys
sys.exit(0 if any(e.get('uuid')=='$ou' for e in json.load(open('$j'))) else 1)
        " 2>/dev/null; then
            echo "   rewrite $j entry $old -> $new"
            planned+=("JSON:$j|$ou|$nu|$new")
        fi
    done
done <<< "$PAIRS"

if [ ${#planned[@]} -eq 0 ]; then
    echo "Nothing to migrate."
    exit 0
fi

if [ "$MODE" != "--apply" ]; then
    echo
    echo "Dry run only — rerun with --apply to perform" \
         "the ${#planned[@]} action(s) above."
    exit 0
fi

backup="playerdata-migration-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
files=()
for p in "${planned[@]}"; do
    case "$p" in
    JSON:*) IFS='|' read -r tag _ _ _ <<<"$p"
            files+=("${tag#JSON:}") ;;
    *)      files+=("${p%%|*}") ;;
    esac
done
tar czf "$backup" "${files[@]}"
echo "Backup: $SERVER_DIR/$backup"

for p in "${planned[@]}"; do
    case "$p" in
    JSON:*)
        IFS='|' read -r tag ou nu new <<<"$p"; j=${tag#JSON:}
        python3 - "$j" "$ou" "$nu" "$new" <<'PY'
import json, sys
path, ou, nu, new = sys.argv[1:5]
data = json.load(open(path))
for e in data:
    if e.get("uuid") == ou:
        e["uuid"] = nu
        e["name"] = new
json.dump(data, open(path, "w"), indent=2)
PY
        ;;
    *)  mv "${p%%|*}" "${p##*|}" ;;
    esac
done
echo "Done. Start the server and have each player verify inventory/position."
