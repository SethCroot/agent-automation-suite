from datetime import datetime, timezone


def test_parse_utc_datetime(reminders):
    dt = reminders.parse_ics_datetime("20260804T090000Z")
    assert dt == datetime(2026, 8, 4, 9, 0, 0, tzinfo=timezone.utc)


def test_parse_naive_datetime_applies_offset(reminders):
    dt = reminders.parse_ics_datetime("20260804T090000", tz_offset=10)
    assert dt == datetime(2026, 8, 3, 23, 0, 0, tzinfo=timezone.utc)


def test_parse_invalid_datetime_returns_none(reminders):
    assert reminders.parse_ics_datetime("not-a-date") is None
    assert reminders.parse_ics_datetime("20260804") is None


def test_parse_single_event(reminders):
    ics = "\r\n".join(
        [
            "BEGIN:VCALENDAR",
            "BEGIN:VEVENT",
            "SUMMARY:Standup",
            "DTSTART:20260804T090000Z",
            "DTEND:20260804T093000Z",
            "LOCATION:Office",
            "END:VEVENT",
            "END:VCALENDAR",
        ]
    )
    events = reminders.parse_ics_events(ics, "work", 0)
    assert len(events) == 1
    ev = events[0]
    assert ev["summary"] == "Standup"
    assert ev["calendar"] == "work"
    assert ev["location"] == "Office"
    assert ev["dtstart"] == datetime(2026, 8, 4, 9, 0, tzinfo=timezone.utc)
    assert ev["dtend"] == datetime(2026, 8, 4, 9, 30, tzinfo=timezone.utc)


def test_parse_event_with_property_parameters(reminders):
    ics = "\r\n".join(
        [
            "BEGIN:VEVENT",
            "SUMMARY;LANGUAGE=en:Dentist",
            "DTSTART;TZID=Australia/Brisbane:20260804T090000",
            "END:VEVENT",
        ]
    )
    events = reminders.parse_ics_events(ics, "personal", 10)
    assert len(events) == 1
    assert events[0]["summary"] == "Dentist"
    assert events[0]["dtstart"] is not None


def test_line_folding_is_unfolded(reminders):
    ics = "\r\n".join(
        [
            "BEGIN:VEVENT",
            "SUMMARY:A very long ti",
            " tle that was folded",
            "DTSTART:20260804T090000Z",
            "END:VEVENT",
        ]
    )
    events = reminders.parse_ics_events(ics, "cal", 0)
    assert events[0]["summary"] == "A very long title that was folded"


def test_multiple_events_and_lf_line_endings(reminders):
    ics = "\n".join(
        [
            "BEGIN:VEVENT",
            "SUMMARY:One",
            "DTSTART:20260804T090000Z",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "SUMMARY:Two",
            "DTSTART:20260804T100000Z",
            "END:VEVENT",
        ]
    )
    events = reminders.parse_ics_events(ics, "cal", 0)
    assert [e["summary"] for e in events] == ["One", "Two"]


def test_env_vars_override_config_file(reminders, tmp_path, monkeypatch):
    config = tmp_path / "config.yaml"
    config.write_text(
        "caldav:\n  url: https://file.example.com\n  username: file-user\n  password: file-pass\n"
    )
    monkeypatch.setenv("CALDAV_URL", "https://env.example.com")
    monkeypatch.delenv("CALDAV_USERNAME", raising=False)
    cfg = reminders.load_config(str(config))
    assert cfg["url"] == "https://env.example.com"
    assert cfg["username"] == "file-user"
