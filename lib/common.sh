#!/usr/bin/env bash
# Common functions for automation suite scripts.
# Source this from any script: source "$(dirname "$0")/../lib/common.sh"

set -euo pipefail

# ─── Config loading ──────────────────────────────────────────────────

# Parse a --config flag from the script's arguments and echo the config path
# (or the empty string when none given). Usage in each script:
#   load_config "$(parse_config_flag "$@")"
# Also accepts a bare path as the first argument for backwards compatibility.
parse_config_flag() {
    local args=("$@")
    local i
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[$i]}" in
            --config)
                echo "${args[$((i + 1))]:-}"
                return 0
                ;;
            --config=*)
                echo "${args[$i]#--config=}"
                return 0
                ;;
            -*)
                # Unknown flags: skip so they don't get treated as paths
                ;;
            *)
                # First bare argument = config path (legacy behaviour)
                echo "${args[$i]}"
                return 0
                ;;
        esac
    done
    echo ""
}

# Load YAML config into shell variables prefixed with CFG_
# Usage: load_config /path/to/config.yaml
#
# Delegates to lib/flatten_config.py: scalars become CFG_SECTION_KEY,
# lists become indexed CFG_SECTION_KEY_0..N vars (what the
# ${!CFG_BACKUP_EXTRA_PATHS_@} loops consume) plus a space-joined form.
# Parse failures are loud (script exits) rather than silently running
# on defaults — cf. issue #3.
load_config() {
    local config_file="${1:-$(dirname "${BASH_SOURCE[0]:-$0}")/../config/config.yaml}"
    local flatten_script
    flatten_script="$(dirname "${BASH_SOURCE[0]}")/flatten_config.py"
    if [ ! -f "$config_file" ]; then
        echo "ERROR: Config file not found: $config_file" >&2
        echo "Copy config/config.example.yaml to config/config.yaml and edit it." >&2
        exit 1
    fi
    # eval the flattener output; if the flattener itself fails (bad YAML,
    # unreadable file) eval sees empty input and succeeds — so guard it
    # explicitly and fail loudly instead of running on defaults (issue #3)
    local flattened
    if ! flattened="$(python3 "$flatten_script" "$config_file")"; then
        echo "ERROR: Failed to parse config: $config_file (see above)" >&2
        exit 1
    fi
    eval "$flattened"
}

# ─── Path resolution ─────────────────────────────────────────────────

# Resolve a path relative to $HOME, expanding ~
resolve_path() {
    local p="$1"
    echo "${p/#\~/$HOME}"
}

# ─── Lock files ──────────────────────────────────────────────────────

# Acquire an exclusive lock to prevent concurrent runs.
# Uses flock(1) so acquisition is atomic — the old check-then-write
# pattern let two instances starting together both take the lock (issue #8).
# Usage: acquire_lock /path/to/lockfile
acquire_lock() {
    local lock_file="$1"
    local lock_fd
    # Open lock file for writing, keeping fd alive for the script's lifetime
    lock_fd=9
    eval "exec ${lock_fd}>\"$lock_file\"" || return 1
    if ! flock -n "$lock_fd"; then
        echo "Another instance is running" >&2
        exit 0
    fi
    echo $$ >&"$lock_fd"
    # Lock is released automatically when the script exits (fd closes)
}

# ─── Output formatting ───────────────────────────────────────────────

# Format a timestamp for reports
timestamp() {
    date '+%Y-%m-%d %H:%M %Z'
}

# Print a section header
section() {
    echo ""
    echo "─── $1 ───"
}
