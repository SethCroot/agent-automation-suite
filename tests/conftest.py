import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent


def load_script(relative_path: str, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def reminders():
    return load_script("calendar/calendar-reminders.py", "calendar_reminders")


@pytest.fixture(scope="session")
def daily_seed():
    return load_script("calendar/calendar-daily-seed.py", "calendar_daily_seed")
