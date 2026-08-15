#!/usr/bin/env python3
"""Flatten a YAML config into shell `export` lines for lib/common.sh.

Scalars become CFG_SECTION_KEY='value'.
Lists become indexed vars (CFG_SECTION_KEY_0, CFG_SECTION_KEY_1, ...)
plus a space-joined CFG_SECTION_KEY for consumers that want a word list
(e.g. vault.canonical_dirs).

All values are shell-quoted with shlex.quote and keys are validated
against [A-Z0-9_]+ so the downstream eval can never be injected via a
crafted config value or key. Parse failures exit nonzero so callers can
fail loudly instead of silently running on defaults (issue #3).
"""

from __future__ import annotations

import re
import shlex
import sys

import yaml

KEY_RE = re.compile(r"^[A-Z0-9_]+$")


def export_line(key: str, value) -> str:
    if not KEY_RE.match(key):
        raise ValueError(f"illegal config key after normalisation: {key!r}")
    return f"export CFG_{key}={shlex.quote(str(value))}"


def flatten(node: dict, prefix: str = "", out: list[str] | None = None) -> list[str]:
    if out is None:
        out = []
    for k, v in node.items():
        key = f"{prefix}{k}".upper().replace("-", "_").replace(".", "_")
        if isinstance(v, dict):
            flatten(v, prefix + k + "_", out)
        elif isinstance(v, list):
            for i, item in enumerate(v):
                out.append(export_line(f"{key}_{i}", item))
            # Joined form only when every item is space-free, else it lies
            if all(" " not in str(item) for item in v):
                out.append(export_line(key, " ".join(str(item) for item in v)))
        elif v is None:
            continue
        elif isinstance(v, (str, int, float, bool)):
            out.append(export_line(key, v))
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: flatten_config.py CONFIG_FILE", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1]) as f:
            data = yaml.safe_load(f)
    except FileNotFoundError:
        print(f"config file not found: {sys.argv[1]}", file=sys.stderr)
        return 1
    except yaml.YAMLError as e:
        print(f"YAML parse error in {sys.argv[1]}: {e}", file=sys.stderr)
        return 1
    if data is None:
        return 0
    if not isinstance(data, dict):
        print(f"top-level YAML must be a mapping, got {type(data).__name__}", file=sys.stderr)
        return 1
    try:
        for line in flatten(data):
            print(line)
    except ValueError as e:
        print(f"config error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
