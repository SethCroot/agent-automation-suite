#!/usr/bin/env bash
# System Status Report — collects and reports system health metrics.
#
# Outputs a formatted report with: system resources, service status,
# project board stats, model/API health, and network connectivity.
# Designed for cron-driven delivery (stdout piped to notifications).
#
# Configuration: sourced from config/config.yaml via lib/common.sh
# Usage: ./monitoring/system-status.sh [--config /path/to/config.yaml]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

load_config "$(parse_config_flag "$@")"

VAULT_PATH=$(resolve_path "${CFG_VAULT_PATH:-$HOME/notes-vault}")
PROJECTS_DIR="$VAULT_PATH/${CFG_VAULT_PROJECTS_DIR:-Projects}"
GATEWAY_SERVICE="${CFG_AGENT_GATEWAY_SERVICE:-agent-gateway}"
NETWORK_IP="${CFG_MONITORING_NETWORK_CHECK_IP:-127.0.0.1}"

# ─── Report builder ──────────────────────────────────────────────────

echo "**System Status Report** $(timestamp)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── 1. System resources ──────────────────────────────────────────────
echo "**System Resources:**"
mem_info=$(free -h --si 2>/dev/null | awk '/^Mem:/{printf "RAM: %s / %s (%.0f%% used)", $3, $2, ($3/$2)*100}' 2>/dev/null || echo "RAM: N/A")
disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "Disk: %s / %s (%s used)", $3, $2, $5}' 2>/dev/null || echo "Disk: N/A")
load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{printf "Load: %s %s %s", $1, $2, $3}' 2>/dev/null || echo "Load: N/A")
uptime_str=$(uptime -p 2>/dev/null | sed 's/up //' || echo "Uptime: N/A")
echo "  ${mem_info}"
echo "  ${disk_info}"
echo "  ${load_avg}"
echo "  Uptime: ${uptime_str}"
echo ""

# ── 2. Gateway / service status ──────────────────────────────────────
echo "**Gateway Service (${GATEWAY_SERVICE}):**"
gw_status=$(systemctl --user is-active "$GATEWAY_SERVICE" 2>/dev/null || echo "unknown")
gw_mem=$(ps -o rss= -p "$(systemctl --user show --property MainPID "$GATEWAY_SERVICE" 2>/dev/null | cut -d= -f2)" 2>/dev/null | awk '{printf "%.0f MB", $1/1024}' || echo "N/A")
gw_uptime=$(systemctl --user show "$GATEWAY_SERVICE" --property ActiveEnterTimestamp 2>/dev/null | cut -d= -f2- || echo "N/A")
echo "  Status: ${gw_status}"
echo "  Memory: ${gw_mem}"
echo "  Since: ${gw_uptime}"
echo ""

# ── 3. Project board stats ───────────────────────────────────────────
echo "**Project Board:**"
idea=0; in_progress=0; blocked=0; done=0
idea_list=""; in_progress_list=""; blocked_list=""

if [ -d "$PROJECTS_DIR" ]; then
    for f in "$PROJECTS_DIR"/*.md; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "README.md" ] && continue

        title=$(grep -m1 '^title:' "$f" | sed 's/^title:\s*//' | xargs 2>/dev/null || basename "$f" .md)
        status=$(grep -m1 '^status:' "$f" | sed 's/^status:\s*//' | xargs 2>/dev/null || echo "unknown")
        owner=$(grep -m1 '^owner:' "$f" | sed 's/^owner:\s*//' | xargs 2>/dev/null || echo "unassigned")

        # grep -c already prints 0 on no match — || echo "0" appends a second
        # line and breaks the arithmetic below — cf. issue #2
        total_tasks=$(grep -cE '^\s*- \[[ x]\]' "$f" 2>/dev/null || true)
        done_tasks=$(grep -cE '^\s*- \[x\]' "$f" 2>/dev/null || true)
        open_tasks=$((total_tasks - done_tasks))

        entry="• ${title} [${owner}] — ${open_tasks} open, ${done_tasks}/${total_tasks} done"

        case "$status" in
            Idea)          idea=$((idea + 1));        idea_list+="${entry}\n" ;;
            In\ Progress)  in_progress=$((in_progress + 1)); in_progress_list+="${entry}\n" ;;
            Blocked)       blocked=$((blocked + 1));  blocked_list+="${entry}\n" ;;
            Done)          done=$((done + 1)) ;;
            *)             in_progress=$((in_progress + 1)); in_progress_list+="${entry}\n" ;;
        esac
    done
fi

echo "  Idea: ${idea} | In Progress: ${in_progress} | Blocked: ${blocked} | Done: ${done}"
echo ""

if [ -n "$blocked_list" ]; then
    echo -e "**Blocked:**\n${blocked_list}"
fi
if [ -n "$in_progress_list" ]; then
    echo -e "**In Progress:**\n${in_progress_list}"
fi

# ── 4. Service health ────────────────────────────────────────────────
echo "**Service Health:**"
recent_errors=$(journalctl --user -u "$GATEWAY_SERVICE" --since "1 hour ago" --no-pager 2>/dev/null | grep -c "ERROR" || true)
echo "  Gateway errors (last 1h): ${recent_errors}"
echo ""

# ── 5. Network connectivity ──────────────────────────────────────────
echo "**Network:**"
tailscale_ip=$(ip addr show tailscale0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || echo "offline")
echo "  Tailscale: ${tailscale_ip}"
host_ping=$(ping -c 1 -W 2 "$NETWORK_IP" >/dev/null 2>&1 && echo "reachable" || echo "unreachable")
echo "  Check host (${NETWORK_IP}): ${host_ping}"
