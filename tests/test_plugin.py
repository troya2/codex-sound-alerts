#!/usr/bin/env python3
"""Dependency-free manifest and native hook tests."""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins" / "codex-sound-alerts"
HOOKS_PATH = PLUGIN / "hooks" / "hooks.json"
MAC_SCRIPT = PLUGIN / "scripts" / "codex-sound-alerts.sh"
WINDOWS_SCRIPT = PLUGIN / "scripts" / "codex-sound-alerts.ps1"


def payload(session_id: str = "session-a", turn_id: str = "turn-a") -> str:
    return json.dumps(
        {
            "session_id": session_id,
            "turn_id": turn_id,
            "hook_event_name": "Test",
            "tool_name": "Bash",
            "tool_input": {"command": "must-not-be-logged"},
        }
    )


class ManifestTests(unittest.TestCase):
    def test_plugin_manifest_and_marketplace_contract(self) -> None:
        manifest = json.loads((PLUGIN / ".codex-plugin" / "plugin.json").read_text())
        marketplace = json.loads(
            (ROOT / ".agents" / "plugins" / "marketplace.json").read_text()
        )

        self.assertEqual(manifest["name"], "codex-sound-alerts")
        self.assertEqual(manifest["version"], "0.1.1")
        self.assertEqual(manifest["license"], "MIT")
        self.assertNotIn("skills", manifest)
        self.assertNotIn("hooks", manifest)
        self.assertEqual(marketplace["name"], "codex-sound-alerts")
        self.assertEqual(len(marketplace["plugins"]), 1)
        entry = marketplace["plugins"][0]
        self.assertEqual(entry["name"], manifest["name"])
        self.assertEqual(entry["source"]["path"], "./plugins/codex-sound-alerts")
        self.assertEqual(entry["policy"]["installation"], "AVAILABLE")
        self.assertEqual(entry["policy"]["authentication"], "ON_INSTALL")

    def test_hook_contract_is_notification_only(self) -> None:
        config = json.loads(HOOKS_PATH.read_text())
        events = config["hooks"]
        self.assertEqual(set(events), {"PermissionRequest", "UserPromptSubmit", "Stop"})

        serialized = json.dumps(config).lower()
        for decision_field in (
            "permissiondecision",
            "decision:allow",
            "decision:deny",
            "updatedpermissions",
        ):
            self.assertNotIn(decision_field, serialized)

        for groups in events.values():
            self.assertEqual(len(groups), 1)
            handler = groups[0]["hooks"][0]
            self.assertEqual(handler["type"], "command")
            self.assertEqual(handler["timeout"], 5)
            self.assertIn("${PLUGIN_ROOT}", handler["command"])
            self.assertIn("${PLUGIN_ROOT}", handler["commandWindows"])

    def test_notifications_use_only_generic_text(self) -> None:
        scripts = MAC_SCRIPT.read_text() + WINDOWS_SCRIPT.read_text()
        self.assertIn("Approval required.", scripts)
        self.assertIn("A long-running task has ended.", scripts)
        self.assertNotIn("must-not-be-logged", scripts)
        self.assertNotIn("tool_input.command", scripts)

    def test_macos_sounds_use_double_gain(self) -> None:
        script = MAC_SCRIPT.read_text()
        self.assertEqual(script.count("/usr/bin/afplay -v 2.0"), 2)


class NativeRuntimeMixin:
    action_command: list[str]

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        temp_path = Path(self.temp.name)
        self.state_dir = temp_path / "plugin data"
        self.log_path = temp_path / "events.log"
        self.external_log_path = temp_path / "external.jsonl"
        if platform.system() == "Windows":
            self.external_hook_path = temp_path / "external-hook.ps1"
            self.external_hook_path.write_text(
                'param([string]$Kind)\n$input | Out-File -Append -Encoding utf8 '
                "$env:CODEX_SOUND_ALERTS_EXTERNAL_LOG\n"
            )
        else:
            self.external_hook_path = temp_path / "external-hook"
            self.external_hook_path.write_text(
                "#!/bin/sh\n/bin/cat >>\"$CODEX_SOUND_ALERTS_EXTERNAL_LOG\"\n"
            )
            self.external_hook_path.chmod(0o700)
        self.env = os.environ.copy()
        self.env.update(
            {
                "PLUGIN_DATA": str(self.state_dir),
                "CODEX_SOUND_ALERTS_TEST_MODE": "1",
                "CODEX_SOUND_ALERTS_TEST_LOG": str(self.log_path),
                "CODEX_SOUND_ALERTS_EXTERNAL_HOOK": str(self.external_hook_path),
                "CODEX_SOUND_ALERTS_EXTERNAL_LOG": str(self.external_log_path),
            }
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_action(
        self, action: str, data: str = payload(), extra_env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        env = self.env.copy()
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [*self.action_command, action],
            input=data,
            text=True,
            capture_output=True,
            env=env,
            timeout=10,
            check=False,
        )

    def events(self) -> list[str]:
        if not self.log_path.exists():
            return []
        return [line.lstrip("\ufeff") for line in self.log_path.read_text(encoding="utf-8-sig").splitlines()]

    def state_files(self) -> list[Path]:
        return list(self.state_dir.glob("state/*.started"))

    def external_events(self) -> list[dict[str, object]]:
        if not self.external_log_path.exists():
            return []
        return [json.loads(line) for line in self.external_log_path.read_text().splitlines()]

    def test_approval_alert_does_not_echo_hook_data(self) -> None:
        result = self.run_action("approval")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            self.events(),
            ["sound:approval", "notification:approval", "external:approval_required"],
        )
        event = self.external_events()[0]
        self.assertEqual(event["version"], 1)
        self.assertEqual(event["event"], "approval_required")
        self.assertEqual(event["title"], "Codex needs attention")
        self.assertNotIn("session_id", event)
        self.assertNotIn("turn_id", event)
        self.assertNotIn("must-not-be-logged", self.log_path.read_text())

    def test_notification_failure_keeps_sound_and_success_exit(self) -> None:
        result = self.run_action(
            "approval", extra_env={"CODEX_SOUND_ALERTS_TEST_NOTIFICATION_FAILURE": "1"}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["sound:approval", "external:approval_required"])

    def test_missing_external_hook_is_ignored(self) -> None:
        missing_hook = str(Path(self.temp.name) / "missing-hook")
        result = self.run_action(
            "approval", extra_env={"CODEX_SOUND_ALERTS_EXTERNAL_HOOK": missing_hook}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["sound:approval", "notification:approval"])
        self.assertEqual(self.external_events(), [])

    def test_short_task_does_not_alert_and_state_is_removed(self) -> None:
        self.assertEqual(self.run_action("start").returncode, 0)
        self.assertEqual(len(self.state_files()), 1)
        self.assertEqual(self.run_action("stop").returncode, 0)
        self.assertEqual(self.events(), [])
        self.assertEqual(self.state_files(), [])

    def test_long_task_alerts_once(self) -> None:
        self.assertEqual(self.run_action("start").returncode, 0)
        state_file = self.state_files()[0]
        state_file.write_text(str(int(time.time()) - 61))
        self.assertEqual(self.run_action("stop").returncode, 0)
        self.assertEqual(
            self.events(),
            ["sound:complete", "notification:complete", "external:task_completed"],
        )
        self.assertEqual(self.run_action("stop").returncode, 0)
        self.assertEqual(
            self.events(),
            ["sound:complete", "notification:complete", "external:task_completed"],
        )

    def test_repeated_start_keeps_the_original_timestamp(self) -> None:
        self.assertEqual(self.run_action("start").returncode, 0)
        state_file = self.state_files()[0]
        original = str(int(time.time()) - 60)
        state_file.write_text(original)
        self.assertEqual(self.run_action("start").returncode, 0)
        self.assertEqual(state_file.read_text(), original)
        self.assertEqual(self.run_action("stop").returncode, 0)
        self.assertEqual(
            self.events(),
            ["sound:complete", "notification:complete", "external:task_completed"],
        )

    def test_concurrent_turns_are_isolated(self) -> None:
        first = payload("session-a", "turn-a")
        second = payload("session-b", "turn-b")
        self.assertEqual(self.run_action("start", first).returncode, 0)
        first_file = self.state_files()[0]
        self.assertEqual(self.run_action("start", second).returncode, 0)
        self.assertEqual(len(self.state_files()), 2)
        first_file.write_text(str(int(time.time()) - 61))

        self.assertEqual(self.run_action("stop", first).returncode, 0)
        self.assertEqual(
            self.events(),
            ["sound:complete", "notification:complete", "external:task_completed"],
        )
        self.assertEqual(self.run_action("stop", second).returncode, 0)
        self.assertEqual(
            self.events(),
            ["sound:complete", "notification:complete", "external:task_completed"],
        )
        self.assertEqual(self.state_files(), [])

    def test_malformed_payload_never_blocks_codex(self) -> None:
        for action in ("start", "stop", "approval"):
            result = self.run_action(action, "{not-json")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")


@unittest.skipUnless(platform.system() == "Darwin", "macOS runtime test")
class MacRuntimeTests(NativeRuntimeMixin, unittest.TestCase):
    action_command = ["/bin/sh", str(MAC_SCRIPT)]


@unittest.skipUnless(platform.system() == "Windows", "Windows runtime test")
class WindowsRuntimeTests(NativeRuntimeMixin, unittest.TestCase):
    action_command = [
        shutil.which("powershell.exe") or "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(WINDOWS_SCRIPT),
        "-Action",
    ]


if __name__ == "__main__":
    unittest.main(verbosity=2)
