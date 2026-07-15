#!/usr/bin/env bash
# Memory TTL Audit — detects stale entries in the agent memory buffer.
#
# Scans the agent's persistent memory file for entries older than the
# configured TTL. Flags expired entries, migrates their content to the
# vault, and reports for manual cleanup. Permanent entries (safety rules,
# core preferences) are never expired.
#
# Silent on clean runs (no expired entries). Designed for weekly cron.
#
# Usage: ./lifecycle/memory-ttl-audit.sh [--config /path/to/config.yaml]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

load_config "${1:-}"

MEMORY_FILE=$(resolve_path "${CFG_AGENT_MEMORY_FILE:-$HOME/.agent/memories/MEMORY.md}")
STATE_FILE="$SCRIPT_DIR/../state/.memory-ttl-state.json"
VAULT_PATH=$(resolve_path "${CFG_VAULT_PATH:-$HOME/notes-vault}")
EXPIRED_DIR="$VAULT_PATH/memory/expired-buffer"
TTL_DAYS="${CFG_MEMORY_TTL_MAX_AGE_DAYS:-7}"
TODAY=$(date +%Y-%m-%d)

# Permanent entry prefixes — configured in config.yaml
# These never expire regardless of age
PERMANENT_FILE="${SCRIPT_DIR}/../state/permanent-prefixes.txt"
if [ ! -f "$PERMANENT_FILE" ]; then
    # Fall back to config-provided prefixes
    mkdir -p "$SCRIPT_DIR/../state"
    # Write permanent prefixes from config if available
    for prefix in "${!CFG_MEMORY_TTL_PERMANENT_PREFIXES_@}"; do
        [ -z "${!prefix:-}" ] && continue
        echo "${!prefix}"
    done > "$PERMANENT_FILE" 2>/dev/null || true
fi

# Ensure state directory exists
mkdir -p "$(dirname "$STATE_FILE")"
if [ ! -f "$STATE_FILE" ]; then
    echo '{"entries":{}, "snapshots":[]}' > "$STATE_FILE"
fi

# Skip if memory file doesn't exist
if [ ! -f "$MEMORY_FILE" ]; then
    exit 0
fi

# Read current buffer entries (split on § delimiter)
mapfile -t -d $'\n' CURRENT_ENTRIES < <(grep -v '^§$' "$MEMORY_FILE" 2>/dev/null || echo "")

FLAGGED=""
MIGRATED=""

for entry in "${CURRENT_ENTRIES[@]}"; do
    [ -z "$entry" ] && continue
    [ "$entry" = "§" ] && continue

    # Check if permanent
    IS_PERMANENT=false
    if [ -f "$PERMANENT_FILE" ]; then
        while IFS= read -r prefix; do
            [ -z "$prefix" ] && continue
            if [[ "$entry" == "$prefix"* ]]; then
                IS_PERMANENT=true
                break
            fi
        done < "$PERMANENT_FILE"
    fi

    [ "$IS_PERMANENT" = true ] && continue

    # Track entry age by hash
    ENTRY_HASH=$(echo -n "$entry" | md5sum | cut -c1-12)
    FIRST_SEEN=$(python3 -c "
import json
try:
    with open('$STATE_FILE') as f:
        state = json.load(f)
    print(state.get('entries', {}).get('$ENTRY_HASH', {}).get('first_seen', ''))
except:
    print('')
" 2>/dev/null || echo "")

    if [ -z "$FIRST_SEEN" ]; then
        # New entry — record it
        python3 -c "
import json
try:
    with open('$STATE_FILE') as f:
        state = json.load(f)
except:
    state = {'entries': {}, 'snapshots': []}
state.setdefault('entries', {})['$ENTRY_HASH'] = {'first_seen': '$TODAY'}
with open('$STATE_FILE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || true
        continue
    fi

    # Calculate age
    AGE_DAYS=$(python3 -c "
from datetime import datetime
d1 = datetime.strptime('$FIRST_SEEN', '%Y-%m-%d')
d2 = datetime.strptime('$TODAY', '%Y-%m-%d')
print((d2 - d1).days)
" 2>/dev/null || echo "0")

    if [ "$AGE_DAYS" -ge "$TTL_DAYS" ]; then
        # Entry has expired
        FLAGGED="${FLAGGED}\n⚠️ Entry (age: ${AGE_DAYS}d, first seen: ${FIRST_SEEN}):\n  ${entry:0:100}...\n"

        # Auto-migrate to vault
        mkdir -p "$EXPIRED_DIR"
        MIGRATION_FILE="${EXPIRED_DIR}/${TODAY}-${ENTRY_HASH}.md"
        {
            echo "---"
            echo "type: expired-buffer"
            echo "expired: ${TODAY}"
            echo "first_seen: ${FIRST_SEEN}"
            echo "age_days: ${AGE_DAYS}"
            echo "---"
            echo ""
            echo "$entry"
        } > "$MIGRATION_FILE"

        MIGRATED="${MIGRATED}\n→ Migrated to: $(basename "$MIGRATION_FILE")"
    fi
done

# Output report (silent if nothing expired)
if [ -z "$FLAGGED" ]; then
    exit 0
else
    echo "🧹 Memory TTL Audit — ${TODAY}"
    echo ""
    echo -e "The following buffer entries have exceeded ${TTL_DAYS}-day TTL:"
    echo -e "$FLAGGED"
    echo -e "$MIGRATED"
    echo ""
    echo "Content has been migrated to vault. Review and remove from buffer if appropriate."
    echo "Permanent entries (safety rules, core preferences) were skipped."
fi
