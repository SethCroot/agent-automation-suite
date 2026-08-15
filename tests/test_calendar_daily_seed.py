from datetime import datetime, timezone, timedelta


def test_parse_ical_dt_utc(daily_seed):
    dt = daily_seed.parse_ical_dt("20260804T090000Z")
    assert dt == datetime(2026, 8, 4, 9, 0, tzinfo=timezone.utc)


def test_parse_ical_dt_naive(daily_seed):
    dt = daily_seed.parse_ical_dt("20260804T090000")
    assert dt == datetime(2026, 8, 4, 9, 0)
    assert dt.tzinfo is None


def test_parse_ical_dt_invalid(daily_seed):
    assert daily_seed.parse_ical_dt("garbage") is None


def test_parse_event_extracts_fields(daily_seed):
    ics = "\r\n".join(
        [
            "BEGIN:VEVENT",
            "SUMMARY:Team lunch",
            "DTSTART:20260804T120000Z",
            "DTEND:20260804T130000Z",
            "LOCATION:Cafe",
            "END:VEVENT",
        ]
    )
    event = daily_seed.parse_event(ics)
    assert event["summary"] == "Team lunch"
    assert event["location"] == "Cafe"
    assert event["dtstart"] == datetime(2026, 8, 4, 12, 0, tzinfo=timezone.utc)
    assert event["dtend"] == datetime(2026, 8, 4, 13, 0, tzinfo=timezone.utc)


def test_is_event_today(daily_seed):
    tz_offset = 0
    local_tz = timezone(timedelta(hours=tz_offset))
    today_event = {"dtstart": datetime.now(local_tz)}
    yesterday_event = {"dtstart": datetime.now(local_tz) - timedelta(days=1)}
    missing_start = {"dtstart": None}
    assert daily_seed.is_event_today(today_event, tz_offset)
    assert not daily_seed.is_event_today(yesterday_event, tz_offset)
    assert not daily_seed.is_event_today(missing_start, tz_offset)


def test_format_event(daily_seed):
    event = {
        "summary": "Standup",
        "dtstart": datetime(2026, 8, 4, 9, 0, tzinfo=timezone.utc),
        "dtend": None,
        "location": "Office",
    }
    cal_info = {"name": "Work", "emoji": "🟢"}
    line = daily_seed.format_event(event, cal_info, 0)
    assert line == "- **09:00** — Standup (Work) 🟢 @ Office"


def test_format_event_without_summary_returns_none(daily_seed):
    event = {"summary": None, "dtstart": None, "dtend": None, "location": None}
    assert daily_seed.format_event(event, {}, 0) is None


def test_has_calendar_section(daily_seed):
    assert daily_seed.has_calendar_section("# Note\n\n## Calendar\n\n- item\n")
    assert not daily_seed.has_calendar_section("# Note\n\n## Tasks\n")


def test_insert_after_frontmatter(daily_seed):
    content = "---\ntype: daily\n---\n\n# Notes\n"
    result = daily_seed.insert_calendar_section(content, ["- **09:00** — Standup"])
    assert result.index("---\ntype: daily\n---\n") < result.index("## Calendar")
    assert result.index("## Calendar") < result.index("# Notes")
    assert "- **09:00** — Standup" in result


def test_insert_without_frontmatter_prepends(daily_seed):
    content = "# Notes\n"
    result = daily_seed.insert_calendar_section(content, ["- **09:00** — Standup"])
    assert result.startswith("## Calendar")
    assert result.endswith("# Notes\n")


def test_insert_with_no_events_is_a_noop(daily_seed):
    content = "---\ntype: daily\n---\n\n# Notes\n"
    assert daily_seed.insert_calendar_section(content, []) == content
