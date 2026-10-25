#!/usr/bin/env python3
"""Add or remove Nubbin's hooks for Claude Code (~/.claude/settings.json) or Codex (~/.codex/hooks.json).

Idempotent: existing Nubbin entries are replaced, other hooks are left alone, and new
entries are appended so the positions of existing ones (which Codex trust is keyed on) stay put.
A timestamped backup is written next to the file before every change.
"""

import argparse
import json
import shlex
import shutil
import time
from pathlib import Path

MARKER = "Nubbin.app/Contents/MacOS/Nubbin"

# agent -> (config file, {event: matcher or None})
TARGETS = {
    "claude": (
        Path.home() / ".claude" / "settings.json",
        {
            "SessionStart": None,
            "UserPromptSubmit": None,
            "PreToolUse": "AskUserQuestion|ExitPlanMode",
            "PermissionRequest": None,
            "PostToolUse": None,
            "Notification": None,
            "Stop": None,
            "StopFailure": None,
            "SessionEnd": None,
        },
    ),
    # Codex has no Notification/StopFailure/SessionEnd hooks; rows in zellij are pruned when the pane closes.
    "codex": (
        Path.home() / ".codex" / "hooks.json",
        {
            "SessionStart": None,
            "UserPromptSubmit": None,
            "PermissionRequest": None,
            "PostToolUse": None,
            "Stop": None,
        },
    ),
}


def strip_ours(hooks: dict) -> dict:
    cleaned = {}
    for event, groups in hooks.items():
        kept_groups = []
        for group in groups:
            entries = [h for h in group.get("hooks", []) if MARKER not in h.get("command", "")]
            if entries:
                kept_groups.append({**group, "hooks": entries})
        if kept_groups:
            cleaned[event] = kept_groups
    return cleaned


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", choices=TARGETS, default="claude")
    parser.add_argument("--binary", help="path to the installed Nubbin executable")
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    if not args.uninstall and not args.binary:
        parser.error("--binary is required unless --uninstall")
    if args.binary and MARKER not in args.binary:
        parser.error(f"--binary must end with {MARKER} so uninstall can find it")

    path, events = TARGETS[args.agent]
    settings = json.loads(path.read_text()) if path.exists() else {}
    if path.exists():
        backup = path.with_name(f"{path.name}.nubbin-{time.strftime('%Y%m%d-%H%M%S')}.bak")
        shutil.copy2(path, backup)
        print(f"backup: {backup}")

    hooks = strip_ours(settings.get("hooks", {}))
    if not args.uninstall:
        command = f"{shlex.quote(args.binary)} hook --agent {args.agent}"
        for event, matcher in events.items():
            # Claude's PermissionRequest hook waits for an Approve/Deny from the notch while the
            # terminal prompt stays usable; everything else returns immediately.
            timeout = 600 if args.agent == "claude" and event == "PermissionRequest" else 5
            group = {"hooks": [{"type": "command", "command": command, "timeout": timeout}]}
            if matcher:
                group = {"matcher": matcher, **group}
            hooks.setdefault(event, []).append(group)

    if hooks:
        settings["hooks"] = hooks
    else:
        settings.pop("hooks", None)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
    print(("removed Nubbin hooks from " if args.uninstall else "installed Nubbin hooks in ") + str(path))


if __name__ == "__main__":
    main()
