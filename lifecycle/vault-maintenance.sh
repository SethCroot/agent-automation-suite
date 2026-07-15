#!/usr/bin/env bash
# Vault Maintenance — structural integrity checks for a notes vault.
#
# Checks for: stray top-level directories, ghost/stale paths in scripts,
# missing YAML frontmatter in markdown files, near-empty files, and
# empty directories. Silent on clean runs.
#
# Designed for daily cron. Only produces output when issues are found.
#
# Usage: ./lifecycle/vault-maintenance.sh [--config /path/to/config.yaml]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

load_config "${1:-}"

VAULT=$(resolve_path "${CFG_VAULT_PATH:-$HOME/notes-vault}")
TODAY=$(date +%Y-%m-%d)

# Canonical directories — configurable via config.yaml
# Default to a standard Obsidian vault structure
CANONICAL_DIRS="${CFG_VAULT_CANONICAL_DIRS:-00-Inbox 01-Daily 02-Projects 03-Knowledge 04-Archive}"

# Stale patterns to check for in scripts (old directory numbers)
# Leave empty to disable this check
STALE_PATTERNS="${CFG_VAULT_STALE_PATTERNS:-}"

ISSUES=""
ISSUE_COUNT=0

add_issue() {
    ISSUE_COUNT=$((ISSUE_COUNT + 1))
    ISSUES="${ISSUES}\n$1"
}

# ─── 1. Check top-level directory structure ──────────────────────────
if [ -d "$VAULT" ]; then
    ACTUAL_DIRS=$(find "$VAULT" -mindepth 1 -maxdepth 1 -type d \
        -not -name '.git' -not -name '.obsidian' \
        -exec basename {} \; | sort)

    for dir in $ACTUAL_DIRS; do
        if ! echo "$CANONICAL_DIRS" | grep -qw "$dir"; then
            add_issue "❌ **Stray directory:** \`$dir/\` — not in canonical structure"
        fi
    done
fi

# ─── 2. Check for stale path references in scripts ───────────────────
if [ -n "$STALE_PATTERNS" ]; then
    SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    STALE_REFS=""
    while IFS= read -r match_line; do
        [ -z "$match_line" ] && continue
        file_path=$(echo "$match_line" | cut -d: -f1)
        line_num=$(echo "$match_line" | cut -d: -f2)
        # Exclude this script (contains patterns by definition)
        case "$file_path" in
            */vault-maintenance.sh) continue ;;
        esac
        STALE_REFS="${STALE_REFS}\n   \`${file_path##*/}\`:${line_num}"
    done < <(grep -rnE "$STALE_PATTERNS" "$SCRIPTS_ROOT" --include='*.sh' --include='*.py' 2>/dev/null || true)

    if [ -n "$STALE_REFS" ]; then
        add_issue "⚠️ **Stale path references in scripts:**${STALE_REFS}\n   These reference outdated directory structures."
    fi
fi

# ─── 3. Check for missing frontmatter ────────────────────────────────
MISSING_FM_COUNT=0
MISSING_FM_LIST=""
while IFS= read -r mdfile; do
    case "$mdfile" in
        */04-Archive/*) continue ;;
        */Templates/*) continue ;;
        */README.md) continue ;;
        */INDEX.md) continue ;;
        */vault-map.md) continue ;;
    esac
    FIRST_LINE=$(head -1 "$mdfile" 2>/dev/null)
    if [ "$FIRST_LINE" != "---" ]; then
        MISSING_FM_COUNT=$((MISSING_FM_COUNT + 1))
        MISSING_FM_LIST="${MISSING_FM_LIST}\n   \`${mdfile#$VAULT/}\`"
    fi
done < <(find "$VAULT" -name '*.md' -not -path '*/.git/*' -not -path '*/.obsidian/*' 2>/dev/null)

if [ "$MISSING_FM_COUNT" -gt 0 ]; then
    add_issue "⚠️ **Missing frontmatter:** $MISSING_FM_COUNT .md files have no YAML frontmatter.${MISSING_FM_LIST}"
fi

# ─── 4. Check for near-empty files ───────────────────────────────────
EMPTY_COUNT=0
EMPTY_LIST=""
while IFS= read -r mdfile; do
    SIZE=$(stat --printf='%s' "$mdfile" 2>/dev/null || echo "0")
    if [ "$SIZE" -lt 50 ]; then
        EMPTY_COUNT=$((EMPTY_COUNT + 1))
        EMPTY_LIST="${EMPTY_LIST}\n   \`${mdfile#$VAULT/}\` (${SIZE}b)"
    fi
done < <(find "$VAULT" -name '*.md' -not -path '*/.git/*' -not -path '*/.obsidian/*' -not -path '*/04-Archive/*' 2>/dev/null)

if [ "$EMPTY_COUNT" -gt 0 ]; then
    add_issue "⚠️ **Near-empty files:** $EMPTY_COUNT .md files under 50 bytes.${EMPTY_LIST}"
fi

# ─── 5. Check for empty directories ──────────────────────────────────
EMPTY_DIRS=""
while IFS= read -r emptydir; do
    EMPTY_DIRS="${EMPTY_DIRS}\n   \`${emptydir#$VAULT/}\`"
done < <(find "$VAULT" -type d -empty -not -path '*/.git/*' -not -path '*/.obsidian/*' 2>/dev/null || true)

if [ -n "$EMPTY_DIRS" ]; then
    add_issue "ℹ️ **Empty directories:**${EMPTY_DIRS}"
fi

# ─── Report ──────────────────────────────────────────────────────────
if [ "$ISSUE_COUNT" -eq 0 ]; then
    exit 0  # Silent — vault is clean
fi

echo "🔧 Vault Maintenance Report — ${TODAY}"
echo ""
echo "Found ${ISSUE_COUNT} issue(s):"
echo -e "$ISSUES"
