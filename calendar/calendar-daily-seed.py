#!/usr/bin/env python3
"""Calendar Daily Seed — injects today's calendar events into a daily note.

Polls a CalDAV server for events occurring today and writes them into
the day's markdown daily note under a ## Calendar section. Idempotent:
skips notes that already have a Calendar section.

Designed for daily cron at 6am. Creates the daily note if it doesn't exist.

Configuration:
    Reads from config/config.yaml (or path via --config).

Usage:
    python calendar/calendar-daily-seed.py [--config config.yaml]
"""

from __future__ import annotations

import argparse
import os
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone, timedelta
from pathlib import Path

import requests
import yaml

import urllib3
urllib3.disable_warnings()


def load_config(config_path: str | None = None) -> dict:
    """Load configuration from YAML file, with env var overrides."""
    config = {}

    if config_path is None:
        default = Path(__file__).parent.parent / "config" / "config.yaml"
        if default.exists():
            config_path = str(default)

    if config_path and Path(config_path).exists():
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}

    caldav = config.get("caldav", {})
    vault = config.get("vault", {})

    return {
        "url": os.environ.get("CALDAV_URL", caldav.get("url", "")),
        "username": os.environ.get("CALDAV_USERNAME", caldav.get("username", "")),
        "password": os.environ.get("CALDAV_PASSWORD", caldav.get("password", "")),
        "timezone_offset": caldav.get("timezone_offset", 0),
        "calendars": caldav.get("calendars", {}),
        "vault_path": os.environ.get(
            "VAULT_PATH", os.path.expanduser(vault.get("path", "~/notes-vault"))
        ),
        "daily_notes_dir": vault.get("daily_notes_dir", "01-Daily"),
    }


def list_calendar_events(base_url: str, cal_path: str, auth: tuple) -> list[str]:
    """List all .ics file hrefs in a calendar via PROPFIND."""
    propfind = """<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop><D:getetag/></D:prop>
</D:propfind>"""

    resp = requests.request(
        "PROPFIND",
        f"{base_url}{cal_path}",
        data=propfind,
        auth=auth,
        headers={"Content-Type": "application/xml", "Depth": "1"},
        verify=False,
    )
    if resp.status_code != 207:
        return []

    hrefs = []
    root = ET.fromstring(resp.text)
    for response in root.findall(".//{DAV:}response"):
        href_elem = response.find(".//{DAV:}href")
        if href_elem is not None and href_elem.text and href_elem.text.endswith(".ics"):
            hrefs.append(href_elem.text)
    return hrefs


def parse_event(ics_content: str) -> dict:
    """Parse ICS content and extract event details."""
    event = {"summary": None, "dtstart": None, "dtend": None, "location": None}
    for line in ics_content.split("\r\n"):
        if line.startswith("SUMMARY:"):
            event["summary"] = line[8:]
        elif line.startswith("DTSTART:"):
            event["dtstart"] = parse_ical_dt(line[8:])
        elif line.startswith("DTEND:"):
            event["dtend"] = parse_ical_dt(line[6:])
        elif line.startswith("LOCATION:"):
            event["location"] = line[9:]
    return event


def parse_ical_dt(dt_str: str) -> datetime | None:
    """Parse iCalendar datetime string."""
    try:
        if dt_str.endswith("Z"):
            return datetime.strptime(dt_str[:-1], "%Y%m%dT%H%M%S").replace(
                tzinfo=timezone.utc
            )
        return datetime.strptime(dt_str, "%Y%m%dT%H%M%S")
    except ValueError:
        return None


def is_event_today(event: dict, tz_offset: int) -> bool:
    """Check if event occurs today in the configured timezone."""
    if not event["dtstart"]:
        return False
    local_tz = timezone(timedelta(hours=tz_offset))
    start_local = event["dtstart"].astimezone(local_tz) if event["dtstart"].tzinfo else event["dtstart"].replace(
        tzinfo=local_tz
    )
    return start_local.date() == datetime.now(local_tz).date()


def format_event(event: dict, cal_info: dict, tz_offset: int) -> str | None:
    """Format an event as a markdown bullet point."""
    if not event["summary"]:
        return None

    local_tz = timezone(timedelta(hours=tz_offset))
    if event["dtstart"]:
        if event["dtstart"].tzinfo:
            start_local = event["dtstart"].astimezone(local_tz)
        else:
            start_local = event["dtstart"].replace(tzinfo=local_tz)
        time_str = start_local.strftime("%H:%M")
    else:
        time_str = "??"

    parts = [f"**{time_str}** — {event['summary']}"]

    cal_name = cal_info.get("name", "") if isinstance(cal_info, dict) else ""
    cal_emoji = cal_info.get("emoji", "") if isinstance(cal_info, dict) else ""
    if cal_name:
        parts.append(f"({cal_name}) {cal_emoji}")

    if event.get("location"):
        parts.append(f"@ {event['location']}")

    return "- " + " ".join(parts)


def get_daily_note_path(vault_path: str, daily_dir: str) -> str:
    """Get path to today's daily note."""
    today = datetime.now().strftime("%Y-%m-%d")
    return str(Path(vault_path) / daily_dir / f"{today}.md")


def ensure_daily_note(note_path: str) -> bool:
    """Create daily note with frontmatter if it doesn't exist."""
    if os.path.exists(note_path):
        return True

    today = datetime.now().strftime("%Y-%m-%d")
    frontmatter = f"""---
status: auto-generated
tags: []
type: daily
updated: '{today}'
---

"""
    try:
        Path(note_path).parent.mkdir(parents=True, exist_ok=True)
        with open(note_path, "w") as f:
            f.write(frontmatter)
        return True
    except OSError as e:
        print(f"Error creating daily note: {e}", file=sys.stderr)
        return False


def has_calendar_section(content: str) -> bool:
    """Check if the note already has a Calendar section."""
    for line in content.split("\n"):
        if line.strip().startswith("## Calendar"):
            return True
    return False


def insert_calendar_section(content: str, events_md: list[str]) -> str:
    """Insert Calendar section after frontmatter."""
    if not events_md:
        return content

    calendar_md = "## Calendar\n\n" + "\n".join(events_md) + "\n"

    if content.startswith("---"):
        fm_end = content.find("---\n", 4)
        if fm_end != -1:
            return content[: fm_end + 4] + "\n" + calendar_md + "\n" + content[fm_end + 4 :]

    return calendar_md + "\n" + content


def main() -> int:
    parser = argparse.ArgumentParser(description="Seed daily note with today's calendar events.")
    parser.add_argument("--config", help="Path to config.yaml")
    args = parser.parse_args()

    cfg = load_config(args.config)

    if not cfg["url"]:
        print("ERROR: CalDAV URL required.", file=sys.stderr)
        return 1

    auth = (cfg["username"], cfg["password"])
    tz_offset = cfg["timezone_offset"]
    note_path = get_daily_note_path(cfg["vault_path"], cfg["daily_notes_dir"])

    print(f"Seeding daily note for {datetime.now().strftime('%Y-%m-%d')}")

    if not ensure_daily_note(note_path):
        return 1

    with open(note_path) as f:
        note_content = f.read()

    if has_calendar_section(note_content):
        print("Daily note already has Calendar section, skipping")
        return 0

    # Collect today's events from all calendars
    all_events: list[str] = []
    for cal_id, cal_info in cfg["calendars"].items():
        cal_name = cal_info.get("name", cal_id) if isinstance(cal_info, dict) else cal_id
        cal_path = cal_info.get("path", "") if isinstance(cal_info, dict) else cal_info
        print(f"Checking {cal_name} calendar...")

        try:
            event_hrefs = list_calendar_events(cfg["url"], cal_path, auth)
            for href in event_hrefs:
                resp = requests.get(
                    f"{cfg['url']}{href}", auth=auth, verify=False, timeout=10
                )
                if resp.status_code == 200:
                    event = parse_event(resp.text)
                    if is_event_today(event, tz_offset):
                        formatted = format_event(event, cal_info, tz_offset)
                        if formatted:
                            all_events.append(formatted)
        except Exception as e:
            print(f"Error fetching {cal_name}: {e}", file=sys.stderr)

    all_events.sort()

    if not all_events:
        print("No events found for today")
        return 0

    updated = insert_calendar_section(note_content, all_events)
    with open(note_path, "w") as f:
        f.write(updated)

    print(f"Added {len(all_events)} events to daily note")
    return 0


if __name__ == "__main__":
    sys.exit(main())
