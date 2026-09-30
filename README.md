# Codex Sound Alerts

English | [简体中文](README.zh-CN.md)

[![Version](https://img.shields.io/badge/version-v0.2.1-2563EB)](https://github.com/mashukui/codex-sound-alerts) [![Codex](https://img.shields.io/badge/Codex-0.144.3%2B-000000?logo=openai&logoColor=white)](https://github.com/openai/codex) ![Platforms](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-555555) [![License](https://img.shields.io/badge/license-MIT-7C3AED)](https://github.com/mashukui/codex-sound-alerts?tab=MIT-1-ov-file)

Codex Sound Alerts is a lightweight plugin that lets you step away from the screen during long Codex tasks. It plays distinct sounds and shows desktop notifications when:

- Codex is waiting for you to approve a permission request.
- A root task finishes after running for at least 60 seconds.

The plugin supports macOS and Windows 10/11. It does not grant permissions, approve actions, inspect the screen, send network requests, or run a background service.

## Requirements

- Codex CLI or Codex app with plugin Hooks and the `PermissionRequest` event. Version 0.144.3 or newer is recommended.
- macOS, or Windows 10/11 with Windows PowerShell 5.1 or newer.

No Python, Node.js, or third-party package is required at runtime.

## Installation

Add the GitHub marketplace source, then install the plugin:

```sh
codex plugin marketplace add mashukui/codex-sound-alerts
codex plugin add codex-sound-alerts@codex-sound-alerts
```

Start a new Codex session after installation. Codex may ask you to review or trust the bundled Hooks once. Review the commands and accept them to enable alerts. Do not use `--dangerously-bypass-hook-trust`.

## Notifications

| Event | Sound | Notification |
| --- | --- | --- |
| Permission approval required | Ping / Exclamation | `Codex needs attention` |
| Task completed after 60 seconds | Glass / Asterisk | `Codex task finished` |

### Notification previews

**Permission approval required**

![Codex permission approval notification](notify_approval_required.png)

**Long-running task completed**

![Codex long-running task completion notification](notify_task_finish.png)

On macOS, sounds play at `2.0` gain (twice `afplay`'s default). Notifications are sent by Script Editor (`osascript`). If they do not appear, enable notifications for Script Editor in **System Settings > Notifications**.

On Windows, the plugin uses a native WinRT Toast. If Toast notifications are unavailable or disabled, the system sound still plays. Windows system sounds do not expose a per-playback gain setting, so they follow the configured system volume. Focus, Do Not Disturb, mute, and operating-system notification settings are always respected.

### Choose which alerts are delivered

Local desktop alerts and external phone/watch alerts can be configured
independently. Create `~/.config/codex-sound-alerts/settings.json` on macOS or
`%APPDATA%\codex-sound-alerts\settings.json` on Windows:

```json
{
  "local_delivery": "both",
  "external_delivery": "completion",
  "include_project": true
}
```

`local_delivery` and `external_delivery` accept:

- `both` for approval and task-completion alerts (the default)
- `completion` for task-completion alerts only

When `include_project` is `true`, the notification title includes a sanitized
version of the working directory's final folder name, such as
`Codex task finished · example-project`. The full path is never included. This
setting defaults to `false` because the project label is also sent to an
external hook when configured.

Set `CODEX_SOUND_ALERTS_SETTINGS` to use a settings file at a different path.

## Phone, watch, and custom notifications

The plugin can also call an optional external notification hook. This keeps the
core plugin dependency-free while allowing integrations with Pushover, ntfy,
Zulip, Slack, or any other service.

On macOS, create an executable at:

```text
~/.config/codex-sound-alerts/external-hook
```

You can instead set `CODEX_SOUND_ALERTS_EXTERNAL_HOOK` to an absolute executable
path. On Windows, the default path is
`%APPDATA%\codex-sound-alerts\external-hook.ps1`.

The hook receives the event name as its first argument and a privacy-safe JSON
object on standard input:

```json
{"version":1,"event":"approval_required","title":"Codex needs attention · example-project","message":"Approval required.","project":"example-project","occurred_at":"2026-09-30T21:30:00Z"}
```

Supported event names are `approval_required` and `task_completed`. The
optional `project` field is present only when `include_project` is enabled.
Commands, prompts, full paths, session IDs, and turn IDs are never included. The plugin stops
the external hook after three seconds, ignores failures, and continues showing
the local sound and desktop notification.

### Pushover on iPhone and Apple Watch

A macOS Pushover example is included at `examples/pushover-hook.sh`. Copy it to
the default hook path, make it executable, then create:

```text
~/.config/codex-sound-alerts/pushover.json
```

with permissions `600` and this content:

```json
{"user":"YOUR_USER_KEY","token":"YOUR_APPLICATION_TOKEN"}
```

Pushover notifications can mirror from the iPhone to Apple Watch when Watch
notifications are enabled for Pushover.

## Privacy and safety

- Approval notifications use generic text and never include commands, paths, prompts, or tool names.
- External hooks receive only the generic event name, title, message, timestamp, schema version, and an optional sanitized project label.
- The approval Hook emits no `allow`, `deny`, or other decision. Codex continues to show its normal approval UI.
- Timing state contains only a hash of the Codex session/turn IDs and a Unix timestamp.
- Timing files live in Codex's plugin data directory, are removed when the turn ends, and stale entries older than seven days are cleaned up.
- Hook failures exit successfully so an audio or notification problem cannot block Codex.

## Uninstall

```sh
codex plugin remove codex-sound-alerts@codex-sound-alerts
codex plugin marketplace remove codex-sound-alerts
```

## Development

Run the dependency-free tests:

```sh
python3 tests/test_plugin.py
```

The test suite runs the native alert script in a test mode that records events instead of playing real sounds or displaying notifications.

## License

[MIT](https://github.com/mashukui/codex-sound-alerts?tab=MIT-1-ov-file)
