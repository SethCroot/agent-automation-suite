#!/bin/bash
# Sync Watchdog — monitors a sync service for healthy activity.
#
# If the service hasn't logged a successful sync within the threshold,
# force-restarts it and verifies recovery. Silent when healthy.
# Designed for cron: empty output = no action needed.
#
# Usage: ./monitoring/sync-watchdog.sh [--config /path/to/config.yaml]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

load_config "$(parse_config_flag "$@")"

SYNC_SERVICE="${CFG_AGENT_SYNC_SERVICE:-obsidian-sync}"
STALE_MINUTES="${CFG_MONITORING_SYNC_STALE_MINUTES:-35}"
VERIFY_WAIT=10

# Check if the service has logged a successful sync recently
# (grep -c prints 0 but exits 1 on no match; || true keeps set -e/pipefail from
#  killing the script before the restart logic can run — cf. issue #1)
LAST_SYNC=$(journalctl --user -u "$SYNC_SERVICE" --since "$STALE_MINUTES minutes ago" --no-pager 2>/dev/null | grep -c "Fully synced\|Connection successful\|sync complete" || true)

if [ "$LAST_SYNC" -eq 0 ]; then
    echo "🔴 Sync Watchdog: no sync activity in ${STALE_MINUTES}min — force restarting ${SYNC_SERVICE}"
    systemctl --user kill "$SYNC_SERVICE" --signal=SIGKILL 2>/dev/null
    sleep 2
    systemctl --user start "$SYNC_SERVICE" 2>/dev/null
    sleep "$VERIFY_WAIT"

    # Verify it recovered
    # (|| true for the same grep -c / pipefail reason as above)
    CONNECTED=$(journalctl --user -u "$SYNC_SERVICE" --since "$((VERIFY_WAIT + 2)) seconds ago" --no-pager 2>/dev/null | grep -c "Connection successful\|Fully synced\|sync complete" || true)
    if [ "$CONNECTED" -gt 0 ]; then
        echo "✅ Sync Watchdog: restart successful, ${SYNC_SERVICE} is active again"
    else
        echo "🚨 Sync Watchdog: RESTART FAILED — ${SYNC_SERVICE} still not syncing after ${VERIFY_WAIT}s. Manual intervention needed."
    fi
fi

# Silent when healthy — no output means everything is fine
