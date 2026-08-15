#!/usr/bin/env bash
# Daily Backup — encrypted vault backup with rotation.
#
# Creates GPG-encrypted tarballs of the notes vault, agent config,
# and any additional configured paths. Retains backups for N days,
# then prunes. Outputs a summary report.
#
# Designed for cron at 2am daily.
#
# Usage: ./lifecycle/backup-daily.sh [--config /path/to/config.yaml]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

load_config "$(parse_config_flag "$@")"

VAULT_PATH=$(resolve_path "${CFG_VAULT_PATH:-$HOME/notes-vault}")
BACKUP_ROOT=$(resolve_path "${CFG_BACKUP_ROOT:-$HOME/backups}")
PASSPHRASE_FILE=$(resolve_path "${CFG_BACKUP_PASSPHRASE_FILE:-}")
RETENTION_DAYS="${CFG_BACKUP_RETENTION_DAYS:-30}"
AGENT_HOME=$(resolve_path "${CFG_AGENT_HOME:-$HOME/.agent}")

DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')

# Create backup directories
mkdir -p "$BACKUP_ROOT/vault"
mkdir -p "$BACKUP_ROOT/config"

echo "=== Starting backup at $TIMESTAMP ==="

# ─── 1. Vault backup (encrypted) ─────────────────────────────────────
echo "[1/3] Backing up vault..."
if [ -n "$PASSPHRASE_FILE" ] && [ -f "$PASSPHRASE_FILE" ]; then
    # Run the tar|gpg pipeline with set -e suspended so the failure branch
    # below is actually reachable (previously set -e killed the script on a
    # failed pipeline, making "Vault backup failed" dead code — issue #8)
    if tar -czf - "$VAULT_PATH" 2>/dev/null | \
        gpg --batch --yes --cipher-algo AES256 --compress-algo 1 \
            --symmetric --passphrase-file "$PASSPHRASE_FILE" \
            > "$BACKUP_ROOT/vault/vault-$DATE.tar.gz.gpg"; then
        SIZE=$(du -h "$BACKUP_ROOT/vault/vault-$DATE.tar.gz.gpg" | cut -f1)
        echo "✓ Vault backup complete: $SIZE"
    else
        echo "✗ Vault backup failed"
    fi
else
    echo "⚠ No passphrase file configured — skipping encrypted vault backup"
    echo "  Set backup.passphrase_file in config.yaml for encrypted backups"
fi

# ─── 2. Agent config backup ──────────────────────────────────────────
echo "[2/3] Backing up agent config..."
if [ -d "$AGENT_HOME" ]; then
    tar -czf "$BACKUP_ROOT/config/config-$DATE.tar.gz" \
        -C "$(dirname "$AGENT_HOME")" "$(basename "$AGENT_HOME")/config.yaml" \
        "$(basename "$AGENT_HOME")/.env" 2>/dev/null || true
    echo "✓ Config backup complete"
else
    echo "⊘ Agent home not found, skipping"
fi

# ─── 3. Additional paths ─────────────────────────────────────────────
EXTRA_COUNT=0
echo "[3/3] Backing up additional paths..."
# Extra paths can be passed as EXTRA_PATH_1, EXTRA_PATH_2, etc. env vars
# or configured in config.yaml under backup.extra_paths
for env_var in "${!CFG_BACKUP_EXTRA_PATHS_@}"; do
    [ -z "${!env_var:-}" ] && continue
    EXTRA_PATH=$(resolve_path "${!env_var}")
    if [ -d "$EXTRA_PATH" ]; then
        DIR_NAME=$(basename "$EXTRA_PATH")
        tar -czf "$BACKUP_ROOT/config/${DIR_NAME}-$DATE.tar.gz" "$EXTRA_PATH" 2>/dev/null
        echo "✓ Backed up: $DIR_NAME"
        EXTRA_COUNT=$((EXTRA_COUNT + 1))
    fi
done

if [ "$EXTRA_COUNT" -eq 0 ]; then
    echo "⊘ No additional paths configured"
fi

# ─── 4. Prune old backups ────────────────────────────────────────────
echo ""
echo "[Cleanup] Pruning backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_ROOT/vault" -name "vault-*.tar.gz.gpg" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null
find "$BACKUP_ROOT/config" -name "*.tar.gz" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null

# ─── 5. Summary ──────────────────────────────────────────────────────
echo ""
echo "=== Backup Summary ==="
echo "Vault backups: $(find "$BACKUP_ROOT/vault" -name "*.tar.gz.gpg" 2>/dev/null | wc -l)"
echo "Config backups: $(find "$BACKUP_ROOT/config" -name "*.tar.gz" 2>/dev/null | wc -l)"
echo "Total disk usage: $(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)"
echo ""
echo "✓ Backup complete at $(date '+%Y-%m-%d %H:%M:%S')"
