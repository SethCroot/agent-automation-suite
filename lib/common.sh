#!/usr/bin/env bash
# Common functions for automation suite scripts.
# Source this from any script: source "$(dirname "$0")/../lib/common.sh"

set -euo pipefail

# ─── Config loading ──────────────────────────────────────────────────

# Load YAML config into shell variables prefixed with CFG_
# Usage: load_config /path/to/config.yaml
load_config() {
    local config_file="${1:-$(dirname "${BASH_SOURCE[0]:-$0}")/../config/config.yaml}"
    if [ ! -f "$config_file" ]; then
        echo "ERROR: Config file not found: $config_file" >&2
        echo "Copy config/config.example.yaml to config/config.yaml and edit it." >&2
        exit 1
    fi
    # Simple YAML parsing: read key: value pairs (2-space indent = section.key)
    eval "$(python3 -c "
import yaml, sys
with open('$config_file') as f:
    data = yaml.safe_load(f)
def flatten(d, prefix=''):
    for k, v in d.items():
        key = f'{prefix}{k}'.upper().replace('-', '_').replace('.', '_')
        if isinstance(v, dict):
            flatten(v, prefix + k + '_')
        elif isinstance(v, (str, int, float, bool)):
            print(f'export CFG_{key}=\"{v}\"')
flatten(data)
" 2>/dev/null)" || true
}

# ─── Path resolution ─────────────────────────────────────────────────

# Resolve a path relative to $HOME, expanding ~
resolve_path() {
    local p="$1"
    echo "${p/#\~/$HOME}"
}

# ─── Lock files ──────────────────────────────────────────────────────

# Acquire a lock to prevent concurrent runs
# Usage: acquire_lock /path/to/lockfile
acquire_lock() {
    local lock_file="$1"
    if [ -f "$lock_file" ]; then
        local pid
        pid=$(cat "$lock_file" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "Another instance is running (PID $pid)" >&2
            exit 0
        fi
    fi
    echo $$ > "$lock_file"
    trap 'rm -f "$lock_file"' EXIT
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
