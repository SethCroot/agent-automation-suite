#!/usr/bin/env bash
# Notify adapter — config-selected delivery backend for script output.
#
# Solves issue #6: delivery depended entirely on cron mail. This wrapper
# sends stdin to a configured backend, falling back to stdout so a
# missing/failing backend never loses a message.
#
# Config (config/config.yaml):
#   notify:
#     backend: ntfy      # ntfy | discord | slack | stdout (default)
#     url: https://ntfy.example.com/agent-alerts
#     title: "automation suite"   # optional, ntfy/slack title
#
# Usage in front of any script's output:
#   ./monitoring/system-status.sh | lib/notify.sh
#   ./lifecycle/backup-daily.sh --config config/config.yaml | lib/notify.sh
#
# Backends:
#   stdout  — passthrough (default; identical to no adapter)
#   ntfy    — single POST, self-hostable, no auth needed for public topics
#   discord — webhook POST {"content": ...} (2000-char body limit, truncated)
#   slack   — webhook POST {"text": ...}
#
# Backend failure is non-fatal: the message is still printed to stdout so
# cron mail remains a safety net.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Config is OPTIONAL here, unlike the other scripts: the adapter's contract
# is "stdout passthrough when unconfigured", and that must hold for setups
# with no config.yaml at all. An explicit --config to a missing file is
# still an error (typo protection); the default path simply may not exist.
NOTIFY_CFG_PATH="$(parse_config_flag "$@")"
if [ -n "$NOTIFY_CFG_PATH" ]; then
    load_config "$NOTIFY_CFG_PATH"   # hard-exits if the given path is missing
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../config/config.yaml" ]; then
    eval "$(python3 "$SCRIPT_DIR/flatten_config.py" "$(dirname "${BASH_SOURCE[0]}")/../config/config.yaml")"
fi

NOTIFY_BACKEND="${CFG_NOTIFY_BACKEND:-stdout}"
NOTIFY_URL="${CFG_NOTIFY_URL:-}"
NOTIFY_TITLE="${CFG_NOTIFY_TITLE:-automation suite}"

send_ntfy() {
    local url="$1" title="$2"
    curl -fsS --max-time 10 \
        -H "Title: $title" \
        --data-binary @- \
        "$url" >/dev/null
}

send_discord() {
    local url="$1" body
    body=$(python3 -c "
import json, sys
msg = sys.stdin.read()
# Discord embed/body limit is 2000 chars for content
print(json.dumps({'content': msg[:1997] + '...' if len(msg) > 2000 else msg}))
")
    curl -fsS --max-time 10 -H "Content-Type: application/json" -d "$body" "$url" >/dev/null
}

send_slack() {
    local url="$1" title="$2" body
    body=$(python3 -c "
import json, sys
msg = sys.stdin.read()
# Slack text limit ~40000 chars; stay conservative
print(json.dumps({'text': f'*{title}*\n' + msg[:38000]}))
")
    curl -fsS --max-time 10 -H "Content-Type: application/json" -d "$body" "$url" >/dev/null
}

main() {
    case "$NOTIFY_BACKEND" in
        stdout|"")
            cat
            return 0
            ;;
        ntfy|discord|slack)
            if [ -z "$NOTIFY_URL" ]; then
                echo "notify: backend=$NOTIFY_BACKEND but notify.url is not set — falling back to stdout" >&2
                cat
                return 0
            fi
            ;;
        *)
            echo "notify: unknown backend '$NOTIFY_BACKEND' — falling back to stdout" >&2
            cat
            return 0
            ;;
    esac

    # Buffer the message so a failed send can still print it.
    if ! MESSAGE=$(cat); then
        return 0
    fi
    [ -z "$MESSAGE" ] && return 0  # nothing to deliver

    case "$NOTIFY_BACKEND" in
        ntfy)    printf '%s' "$MESSAGE" | send_ntfy "$NOTIFY_URL" "$NOTIFY_TITLE" || SENT=no ;;
        discord) printf '%s' "$MESSAGE" | send_discord "$NOTIFY_URL" || SENT=no ;;
        slack)   printf '%s' "$MESSAGE" | send_slack "$NOTIFY_URL" "$NOTIFY_TITLE" || SENT=no ;;
    esac

    if [ "${SENT:-yes}" = "no" ]; then
        echo "notify: $NOTIFY_BACKEND delivery failed — message follows (stdout fallback)" >&2
        printf '%s\n' "$MESSAGE"
        return 0
    fi

    # Success: still echo so piping to a log file keeps working.
    printf '%s\n' "$MESSAGE"
    return 0
}

main
