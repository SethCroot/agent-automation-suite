#!/usr/bin/env python3
"""Calendar Reminder Checker — finds events starting within a time window.

Polls a CalDAV server (Radicale, Nextcloud, Baikal, etc.) for upcoming
calendar events and outputs JSON with events starting within the next
N minutes. Designed for cron-driven reminders.

First run records no baseline — all events within the window are reported.

Configuration:
    Reads from config/config.yaml (or path via --config).
    Credentials can also come from environment variables:
      CALDAV_URL, CALDAV_USERNAME, CALDAV_PASSWORD

Usage:
    python calendar/calendar-reminders.py [--config config.yaml] [--window 15]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib3
import xml.etree.ElementTree as ET
from datetime import datetime, timezone, timedelta
from pathlib import Path

import requests
import yaml
from requests.auth import HTTPBasicAuth

urllib3.disable_warnings()


def load_config(config_path: str | None = None) -> dict:
    """Load configuration from YAML file, with env var overrides."""
    config = {}

    # Try to load YAML
    if config_path is None:
        # Default: look relative to this script's location
        default = Path(__file__).parent.parent / "config" / "config.yaml"
        if default.exists():
            config_path = str(default)

    if config_path and Path(config_path).exists():
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}

    caldav = config.get("caldav", {})
    vault = config.get("vault", {})

    # Environment variable overrides (take precedence)
    return {
        "url": os.environ.get("CALDAV_URL", caldav.get("url", "")),
        "username": os.environ.get("CALDAV_USERNAME", caldav.get("username", "")),
        "password": os.environ.get("CALDAV_PASSWORD", caldav.get("password", "")),
        "timezone_offset": caldav.get("timezone_offset", 0),
        "calendars": caldav.get("calendars", {}),
        "vault_path": os.environ.get("VAULT_PATH", vault.get("path", "")),
    }


def parse_ics_datetime(dt_str: str, tz_offset: int = 0) -> datetime | None:
    """Parse an iCalendar datetime string to a UTC datetime."""
    dt_str = dt_str.strip()
    try:
        if dt_str.endswith("Z"):
            dt = datetime.strptime(dt_str, "%Y%m%dT%H%M%SZ")
            return dt.replace(tzinfo=timezone.utc)
        else:
            dt = datetime.strptime(dt_str, "%Y%m%dT%H%M%S")
            local_tz = timezone(timedelta(hours=tz_offset))
            dt = dt.replace(tzinfo=local_tz)
            return dt.astimezone(timezone.utc)
    except ValueError:
        return None


def parse_ics_events(ics_text: str, cal_name: str, tz_offset: int) -> list[dict]:
    """Parse iCalendar VEVENT entries from raw ICS text."""
    events = []
    lines = []
    # Handle line folding (RFC 5545)
    for line in ics_text.replace("\r\n", "\n").split("\n"):
        if line and line[0] in (" ", "\t") and lines:
            lines[-1] += line[1:]
        else:
            lines.append(line)

    in_event = False
    event: dict = {}
    for line in lines:
        if line == "BEGIN:VEVENT":
            in_event = True
            event = {"calendar": cal_name}
        elif line == "END:VEVENT":
            if event:
                events.append(event)
            in_event = False
        elif in_event and ":" in line:
            prop_part, value = line.split(":", 1)
            props = prop_part.split(";")
            prop_name = props[0].upper()

            if prop_name == "SUMMARY":
                event["summary"] = value
            elif prop_name == "DTSTART":
                event["dtstart"] = parse_ics_datetime(value, tz_offset)
            elif prop_name == "DTEND":
                event["dtend"] = parse_ics_datetime(value, tz_offset)
            elif prop_name == "LOCATION":
                event["location"] = value
            elif prop_name == "DESCRIPTION":
                event["description"] = value

    return events


def fetch_calendar_events(
    base_url: str, cal_path: str, auth: tuple, timeout: int = 10
) -> str:
    """Fetch all .ics events from a calendar via PROPFIND + GET."""
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
        timeout=timeout,
    )
    if resp.status_code not in (200, 207):
        return ""

    # Extract .ics hrefs from the PROPFIND response
    ics_contents = []
    root = ET.fromstring(resp.text)
    for response in root.findall(".//{DAV:}response"):
        href_elem = response.find(".//{DAV:}href")
        if href_elem is not None and href_elem.text and href_elem.text.endswith(".ics"):
            event_resp = requests.get(
                f"{base_url}{href_elem.text}", auth=auth, verify=False, timeout=timeout
            )
            if event_resp.status_code == 200:
                ics_contents.append(event_resp.text)

    return "\n".join(ics_contents)


def main() -> int:
    parser = argparse.ArgumentParser(description="Check for upcoming calendar events.")
    parser.add_argument("--config", help="Path to config.yaml")
    parser.add_argument(
        "--window", type=int, default=15, help="Minutes ahead to check (default: 15)"
    )
    args = parser.parse_args()

    cfg = load_config(args.config)

    if not cfg["url"] or not cfg["username"]:
        print("ERROR: CalDAV URL and username required.", file=sys.stderr)
        print("Set in config.yaml or via CALDAV_URL/CALDAV_USERNAME env vars.", file=sys.stderr)
        return 1

    auth = (cfg["username"], cfg["password"])
    tz_offset = cfg["timezone_offset"]

    now_utc = datetime.now(timezone.utc)
    now_local = now_utc + timedelta(hours=tz_offset)
    window_end = now_utc + timedelta(minutes=args.window)

    # Fetch events from all configured calendars
    all_events: list[dict] = []
    for cal_name, cal_info in cfg["calendars"].items():
        cal_path = cal_info.get("path", cal_info) if isinstance(cal_info, dict) else cal_info
        try:
            ics_text = fetch_calendar_events(cfg["url"], cal_path, auth)
            if ics_text:
                events = parse_ics_events(ics_text, cal_name, tz_offset)
                all_events.extend(events)
        except Exception:
            pass

    # Filter to events starting within the window
    upcoming = []
    for ev in all_events:
        dt_start = ev.get("dtstart")
        if dt_start is None:
            continue
        if now_utc <= dt_start <= window_end:
            local_start = dt_start + timedelta(hours=tz_offset)
            dt_end = ev.get("dtend", dt_start)
            local_end = dt_end + timedelta(hours=tz_offset) if dt_end else local_start
            upcoming.append(
                {
                    "summary": ev.get("summary", "(no title)"),
                    "calendar": ev["calendar"],
                    "start_local": local_start.strftime("%H:%M"),
                    "end_local": local_end.strftime("%H:%M"),
                    "location": ev.get("location", ""),
                    "minutes_until": int((dt_start - now_utc).total_seconds() / 60),
                }
            )

    # Output JSON for downstream parsing
    print(
        json.dumps(
            {
                "now_utc": now_utc.strftime("%Y-%m-%d %H:%M UTC"),
                "now_local": now_local.strftime("%Y-%m-%d %H:%M"),
                "total_events_scanned": len(all_events),
                "upcoming": upcoming,
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
