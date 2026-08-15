#!/usr/bin/env bash
# Kanban Notifier — reads project status from markdown frontmatter.
#
# Scans the vault's Projects directory for .md files with YAML frontmatter,
# extracts status (Idea / In Progress / Blocked / Done), and reports
# blocked and in-progress items. Designed for periodic cron delivery.
#
# Uses a lock file to prevent concurrent runs. State tracking via timestamp.
#
# Usage: ./tracking/kanban-notifier.sh [--config /path/to/config.yaml]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

load_config "$(parse_config_flag "$@")"

VAULT=$(resolve_path "${CFG_VAULT_PATH:-$HOME/notes-vault}")
PROJECTS_DIR="$VAULT/${CFG_VAULT_PROJECTS_DIR:-Projects}"
STATE_DIR="$SCRIPT_DIR/../state"

mkdir -p "$STATE_DIR"
LOCK_FILE="$STATE_DIR/.kanban-notifier.lock"
STATE_FILE="$STATE_DIR/.kanban-notifier-state"

acquire_lock "$LOCK_FILE"

msg=""
needs_notify=false
blocked_list=""
in_progress_list=""
blocked=0; in_progress=0; idea=0; done=0

if [ -d "$PROJECTS_DIR" ]; then
    for f in "$PROJECTS_DIR"/*.md; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "README.md" ] && continue

        title=$(grep -m1 '^title:' "$f" | sed 's/^title:\s*//' | xargs 2>/dev/null || basename "$f" .md)
        status=$(grep -m1 '^status:' "$f" | sed 's/^status:\s*//' | xargs 2>/dev/null || echo "unknown")
        owner=$(grep -m1 '^owner:' "$f" | sed 's/^owner:\s*//' | xargs 2>/dev/null || echo "unassigned")

        # grep -c already prints 0 on no match; || echo "0" would append a
        # second line and break the arithmetic below — cf. issue #2
        total_tasks=$(grep -cE '^\s*- \[[ x]\]' "$f" 2>/dev/null || true)
        done_tasks=$(grep -cE '^\s*- \[x\]' "$f" 2>/dev/null || true)
        open_tasks=$((total_tasks - done_tasks))

        case "$status" in
            Idea)
                idea=$((idea + 1))
                ;;
            In\ Progress)
                in_progress=$((in_progress + 1))
                in_progress_list+="• ${title} [${owner}] — ${open_tasks} open, ${done_tasks}/${total_tasks} done\n"
                ;;
            Blocked)
                blocked=$((blocked + 1))
                blocked_list+="• ${title} [${owner}] — BLOCKED (${open_tasks} open tasks)\n"
                ;;
            Done)
                done=$((done + 1))
                ;;
            *)
                in_progress=$((in_progress + 1))
                in_progress_list+="• ${title} [${owner}] — ${open_tasks} open tasks\n"
                ;;
        esac
    done
fi

# Always report blocked items
if [ -n "$blocked_list" ]; then
    msg+="**Blocked (${blocked}):**\n${blocked_list}\n"
    needs_notify=true
fi

# Report in-progress items
if [ -n "$in_progress_list" ]; then
    msg+="**In Progress (${in_progress}):**\n${in_progress_list}\n"
    needs_notify=true
fi

# Board summary
total=$((idea + in_progress + blocked + done))
if [ "$total" -gt 0 ]; then
    msg+="**Board:** idea:${idea} in-progress:${in_progress} blocked:${blocked} done:${done}\n"
    needs_notify=true
fi

# Update state timestamp
date -Iseconds > "$STATE_FILE"

if [ "$needs_notify" = true ]; then
    echo -e "$msg"
fi
