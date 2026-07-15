# Agent Automation Suite

A collection of cron-driven automation scripts for an AI agent platform. Monitors system health, manages calendars, handles data lifecycle, and tracks project status. Designed to run silently and only speak when something needs attention.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    Cron Scheduler                     │
│                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐ │
│  │ Monitoring  │  │  Calendar   │  │  Lifecycle   │ │
│  │             │  │             │  │              │ │
│  │ • Status    │  │ • Reminders │  │ • Backups    │ │
│  │ • Watchdog  │  │ • Daily     │  │ • TTL Audit  │ │
│  │             │  │   Seeding   │  │ • Maintenance│ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬───────┘ │
│         │                │                │          │
│  ┌──────┴────────────────┴────────────────┴───────┐ │
│  │              lib/common.sh                      │ │
│  │  Config loading · Path resolution · Locks       │ │
│  └─────────────────────┬───────────────────────────┘ │
│                        │                             │
│                 ┌──────┴──────┐                      │
│                 │ config.yaml │                      │
│                 └─────────────┘                      │
└──────────────────────────────────────────────────────┘
```

Every script follows the same pattern:

1. **Load config** from `config/config.yaml` (or environment variables)
2. **Execute** its specific task
3. **Output** results to stdout (captured by cron delivery)
4. **Stay silent** when there's nothing to report

This "speak only when necessary" design means the automation layer is always running but never noisy. A clean vault produces no output from the maintenance script. A healthy sync service produces no output from the watchdog. Output = action needed.

## Modules

### Monitoring (`monitoring/`)

| Script | Schedule | Purpose |
|--------|----------|---------|
| `system-status.sh` | Every 6 hours | Collects system resources (RAM, disk, load, uptime), service status, project board stats, and network connectivity into a formatted report |
| `sync-watchdog.sh` | Every 30 min | Monitors a sync service for healthy activity. Force-restarts if stale, verifies recovery, alerts if restart fails |

### Calendar (`calendar/`)

| Script | Schedule | Purpose |
|--------|----------|---------|
| `calendar-reminders.py` | Every 15 min | Polls a CalDAV server for events starting within the next 15 minutes. Outputs JSON for downstream notification |
| `calendar-daily-seed.py` | Daily at 6am | Injects today's calendar events into the daily markdown note. Creates the note if it doesn't exist. Idempotent |

### Lifecycle (`lifecycle/`)

| Script | Schedule | Purpose |
|--------|----------|---------|
| `backup-daily.sh` | Daily at 2am | Creates GPG-encrypted tarballs of the vault and config. Rotates old backups based on retention policy |
| `memory-ttl-audit.sh` | Weekly | Detects stale entries in the agent memory buffer. Migrates expired content to the vault. Permanent entries (safety rules) never expire |
| `vault-maintenance.sh` | Daily | Structural integrity checks: stray directories, missing frontmatter, near-empty files, empty directories. Silent when clean |

### Tracking (`tracking/`)

| Script | Schedule | Purpose |
|--------|----------|---------|
| `kanban-notifier.sh` | Periodic | Reads project status from markdown frontmatter. Reports blocked and in-progress items from the project board |

## Setup

### Prerequisites

- Bash 4.0+
- Python 3.10+
- `PyYAML` and `requests` Python packages
- `gpg` (for encrypted backups)
- A CalDAV server (Radicale, Nextcloud, Baikal, etc.)
- A notes vault (Obsidian, plain markdown, etc.)

### Installation

```bash
git clone https://github.com/SethCroot/agent-automation-suite.git
cd agent-automation-suite

# Install Python dependencies
pip install -r requirements.txt

# Create your config
cp config/config.example.yaml config/config.yaml
# Edit config.yaml with your settings

# Make scripts executable
chmod +x monitoring/*.sh calendar/*.py lifecycle/*.sh tracking/*.sh lib/*.sh

# Test a script
./monitoring/system-status.sh
```

### Configuration

All configuration lives in `config/config.yaml` (gitignored). Environment variables override YAML values for deployment flexibility:

```bash
# Override CalDAV credentials via env vars
export CALDAV_URL=https://cal.example.com
export CALDAV_USERNAME=user
export CALDAV_PASSWORD=secret

# Or put everything in config.yaml
```

Key configuration sections:

```yaml
caldav:
  url: https://cal.example.com
  username: user
  password: secret
  timezone_offset: 10          # UTC offset for local time display

vault:
  path: ~/notes-vault
  daily_notes_dir: 01-Daily
  projects_dir: Projects

backup:
  root: ~/backups
  passphrase_file: ~/.agent/.backup-pass
  retention_days: 30
```

### Cron Schedule

Example crontab entries:

```cron
# Monitoring
0 */6 * * *     /path/to/agent-automation-suite/monitoring/system-status.sh
*/30 * * * *    /path/to/agent-automation-suite/monitoring/sync-watchdog.sh

# Calendar
*/15 * * * *    /path/to/agent-automation-suite/calendar/calendar-reminders.py --window 15
0 6 * * *       /path/to/agent-automation-suite/calendar/calendar-daily-seed.py

# Lifecycle
0 2 * * *       /path/to/agent-automation-suite/lifecycle/backup-daily.sh
0 0 * * 0       /path/to/agent-automation-suite/lifecycle/memory-ttl-audit.sh
0 4 * * *       /path/to/agent-automation-suite/lifecycle/vault-maintenance.sh

# Tracking
0 9 * * *       /path/to/agent-automation-suite/tracking/kanban-notifier.sh
```

For agent platforms with built-in scheduling (Hermes, etc.), wire scripts as `no_agent` cron jobs that deliver stdout to a notification channel.

## Design Principles

**Silent by default.** Scripts produce no output when everything is fine. Output means something needs attention. This makes cron-driven delivery clean: empty stdout is suppressed, non-empty stdout triggers a notification.

**Config over code.** All paths, credentials, and thresholds live in `config.yaml`. No hardcoded values. Scripts work across different environments without code changes.

**Idempotent operations.** Running `calendar-daily-seed.py` twice produces the same result. The maintenance script doesn't create artifacts. Backups overwrite by date.

**Lock files for safety.** Scripts that shouldn't run concurrently (kanban notifier) use PID-based lock files with automatic cleanup.

**Markdown-native.** Project status is read from markdown frontmatter. Calendar events are written into markdown notes. The vault is the source of truth, not a database.

## Project Structure

```
agent-automation-suite/
├── monitoring/
│   ├── system-status.sh          # System health report
│   └── sync-watchdog.sh           # Service auto-recovery
├── calendar/
│   ├── calendar-reminders.py      # Upcoming event polling
│   └── calendar-daily-seed.py     # Daily note calendar injection
├── lifecycle/
│   ├── backup-daily.sh            # Encrypted backup rotation
│   ├── memory-ttl-audit.sh        # Stale memory detection
│   └── vault-maintenance.sh       # Structural integrity checks
├── tracking/
│   └── kanban-notifier.sh         # Project board alerts
├── lib/
│   └── common.sh                  # Shared config/path/lock helpers
├── config/
│   └── config.example.yaml        # Configuration template
├── state/                         # Runtime state (gitignored)
├── .gitignore
├── requirements.txt
├── LICENSE
└── README.md
```

## License

MIT
