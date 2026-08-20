#!/usr/bin/env python3
"""Manage herdr-team entries in Copilot's canonical skill library."""

from __future__ import annotations

import argparse
import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any


ARTIFACTS = (
    ("orchestrate", "skill", "skills/orchestrate", ("orchestration", "delegation", "herdr")),
    ("pre-pr-review", "skill", "skills/pre-pr-review", ("review", "pull-request", "quality")),
    ("orchestrator", "agent", "agents/orchestrator.md", ("orchestration", "delegation", "agent")),
    ("pre-pr-reviewer", "agent", "agents/pre-pr-reviewer.md", ("review", "pull-request", "agent")),
)
OWNED_NAMES = {artifact[0] for artifact in ARTIFACTS}
BACKUP_NAME = ".herdr-team-library.json.bak"


def description_from_frontmatter(path: Path) -> str:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        raise ValueError(f"{path} has no YAML frontmatter")
    for index, line in enumerate(lines[1:], 1):
        if line.startswith("description:"):
            value = line.partition(":")[2].strip()
            if value not in {">", ">-", "|", "|-"}:
                return value.strip("\"'")
            description = []
            for continuation in lines[index + 1 :]:
                if continuation and not continuation[0].isspace():
                    break
                description.append(continuation.strip())
            return " ".join(part for part in description if part)
        if line == "---":
            break
    raise ValueError(f"{path} has no description in its YAML frontmatter")


def expected_items(bundle: Path) -> list[dict[str, Any]]:
    items = []
    for name, item_type, relative_path, tags in ARTIFACTS:
        source = bundle / relative_path
        items.append(
            {
                "name": name,
                "type": item_type,
                "description": description_from_frontmatter(
                    source / "SKILL.md" if item_type == "skill" else source
                ),
                "path": relative_path,
                "tags": list(tags),
                "requires": [],
            }
        )
    return items


def load(path: Path) -> tuple[Any, list[dict[str, Any]], bytes]:
    raw = path.read_bytes()
    data = json.loads(raw)
    if isinstance(data, list):
        items = data
    elif isinstance(data, dict) and isinstance(data.get("items"), list):
        items = data["items"]
    else:
        raise ValueError(f"{path} must be a JSON array or an object with an items array")
    if not all(isinstance(item, dict) for item in items):
        raise ValueError(f"{path} contains a non-object item")
    return data, items, raw


def set_items(data: Any, items: list[dict[str, Any]]) -> Any:
    if isinstance(data, list):
        return items
    updated = dict(data)
    updated["items"] = items
    return updated


def atomic_bytes(path: Path, content: bytes, mode: int) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def atomic_json(path: Path, data: Any, mode: int) -> None:
    content = (json.dumps(data, indent=2, ensure_ascii=False) + "\n").encode()
    atomic_bytes(path, content, mode)


def back_up(registry: Path, backup: Path, raw: bytes) -> None:
    if backup.exists():
        return
    mode = stat.S_IMODE(registry.stat().st_mode)
    atomic_bytes(backup, raw, mode)


def register(library: Path, bundle: Path, dry_run: bool) -> int:
    registry = library / "library.json"
    backup = library / BACKUP_NAME
    data, items, raw = load(registry)
    expected = expected_items(bundle)
    by_name = {item["name"]: item for item in expected}
    updated_items: list[dict[str, Any]] = []
    seen: set[str] = set()
    changed = False

    for item in items:
        name = item.get("name")
        if name not in by_name:
            updated_items.append(item)
            continue
        if name in seen:
            changed = True
            continue
        seen.add(name)
        updated = dict(item)
        updated.update(by_name[name])
        changed |= updated != item
        updated_items.append(updated)

    for item in expected:
        if item["name"] not in seen:
            updated_items.append(item)
            changed = True

    if dry_run:
        print("would register library.json entries" if changed else "ok           library.json entries already registered")
        return 0

    back_up(registry, backup, raw)
    if changed:
        atomic_json(registry, set_items(data, updated_items), stat.S_IMODE(registry.stat().st_mode))
        print("registered   library.json entries")
    else:
        print("ok           library.json entries already registered")
    return 0


def without_owned(data: Any, items: list[dict[str, Any]]) -> Any:
    return set_items(data, [item for item in items if item.get("name") not in OWNED_NAMES])


def unregister(library: Path, dry_run: bool) -> int:
    registry = library / "library.json"
    backup = library / BACKUP_NAME
    if not registry.exists():
        if backup.exists() and not dry_run:
            atomic_bytes(
                registry,
                backup.read_bytes(),
                stat.S_IMODE(backup.stat().st_mode),
            )
            backup.unlink()
            print("restored     library.json")
        else:
            print(f"not present  {registry}")
        return 0

    current_data, current_items, current_raw = load(registry)
    current_mode = stat.S_IMODE(registry.stat().st_mode)

    if backup.exists():
        original_data, original_items, original_raw = load(backup)
        unrelated_unchanged = without_owned(current_data, current_items) == without_owned(
            original_data, original_items
        )
        if dry_run:
            print("would restore library.json entries")
            return 0
        if unrelated_unchanged:
            atomic_bytes(registry, original_raw, stat.S_IMODE(backup.stat().st_mode))
        else:
            restored = [item for item in current_items if item.get("name") not in OWNED_NAMES]
            restored.extend(item for item in original_items if item.get("name") in OWNED_NAMES)
            atomic_json(registry, set_items(current_data, restored), current_mode)
        backup.unlink()
        print("restored     library.json entries")
        return 0

    updated = without_owned(current_data, current_items)
    if updated == current_data:
        print("not present  library.json entries")
    elif dry_run:
        print("would remove library.json entries")
    else:
        atomic_json(registry, updated, current_mode)
        print("removed      library.json entries")
    return 0


def check(library: Path, bundle: Path, name: str) -> int:
    expected = {item["name"]: item for item in expected_items(bundle)}[name]
    _, items, _ = load(library / "library.json")
    matches = [item for item in items if item.get("name") == name]
    if len(matches) != 1:
        print(f"expected one {name!r} entry, found {len(matches)}")
        return 1
    differences = [
        key for key, value in expected.items() if matches[0].get(key) != value
    ]
    if differences:
        print(f"{name!r} has stale fields: {', '.join(differences)}")
        return 1
    print(f"{name!r} is registered")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("register", "unregister", "check"))
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--name", choices=sorted(OWNED_NAMES))
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()

    try:
        if arguments.action == "register":
            if arguments.bundle is None:
                parser.error("register requires --bundle")
            return register(arguments.library, arguments.bundle, arguments.dry_run)
        if arguments.action == "unregister":
            return unregister(arguments.library, arguments.dry_run)
        if arguments.bundle is None or arguments.name is None:
            parser.error("check requires --bundle and --name")
        return check(arguments.library, arguments.bundle, arguments.name)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"library registry error: {error}", file=os.sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
