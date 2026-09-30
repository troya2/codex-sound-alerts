#!/bin/sh

# Codex passes hook details on stdin. Only IDs and timestamps are persisted.
set -u
umask 077

ACTION="${1:-}"
THRESHOLD_SECONDS=60
EXTERNAL_HOOK_TIMEOUT_SECONDS=3
PAYLOAD="$(/bin/cat 2>/dev/null || true)"
SETTINGS_PATH="${CODEX_SOUND_ALERTS_SETTINGS:-${HOME:-}/.config/codex-sound-alerts/settings.json}"

extract_json_field() {
  printf '%s' "$PAYLOAD" \
    | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}

state_path() {
  session_id="$(extract_json_field session_id)" || return 1
  turn_id="$(extract_json_field turn_id)" || return 1
  [ -n "$session_id" ] && [ -n "$turn_id" ] || return 1
  key="$(printf '%s\n%s' "$session_id" "$turn_id" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  [ -n "$key" ] || return 1
  printf '%s/state/%s.started' "$PLUGIN_DATA" "$key"
}

record_test_event() {
  [ -n "${CODEX_SOUND_ALERTS_TEST_LOG:-}" ] || return 0
  printf '%s\n' "$1" >>"$CODEX_SOUND_ALERTS_TEST_LOG" 2>/dev/null || true
}

setting_value() {
  [ -f "$SETTINGS_PATH" ] || return 1
  /usr/bin/plutil -extract "$1" raw -o - "$SETTINGS_PATH" 2>/dev/null
}

delivery_enabled() {
  channel="$1"
  event_name="$2"
  mode="$(setting_value "${channel}_delivery")" || mode="both"

  case "$mode" in
    both) return 0 ;;
    completion) [ "$event_name" = "task_completed" ] ;;
    *) return 0 ;;
  esac
}

project_label() {
  include_project="$(setting_value include_project)" || return 1
  [ "$include_project" = "true" ] || return 1
  cwd="$(extract_json_field cwd)" || return 1
  [ -n "$cwd" ] || return 1
  project="$(/usr/bin/basename "$cwd" 2>/dev/null \
    | /usr/bin/sed 's/[^A-Za-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')"
  [ -n "$project" ] || return 1
  printf '%s' "$project"
}

run_external_hook() {
  event_name="$1"
  title="$2"
  message="$3"
  project="$4"
  hook_path="${CODEX_SOUND_ALERTS_EXTERNAL_HOOK:-${HOME:-}/.config/codex-sound-alerts/external-hook}"

  delivery_enabled external "$event_name" || return 0
  [ -n "$hook_path" ] && [ -f "$hook_path" ] && [ -x "$hook_path" ] || return 0

  occurred_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  if [ -n "$project" ]; then
    event_json="{\"version\":1,\"event\":\"$event_name\",\"title\":\"$title\",\"message\":\"$message\",\"project\":\"$project\",\"occurred_at\":\"$occurred_at\"}"
  else
    event_json="{\"version\":1,\"event\":\"$event_name\",\"title\":\"$title\",\"message\":\"$message\",\"occurred_at\":\"$occurred_at\"}"
  fi

  if [ "${CODEX_SOUND_ALERTS_TEST_MODE:-}" = "1" ]; then
    record_test_event "external:$event_name"
  fi

  (
    printf '%s\n' "$event_json" | "$hook_path" "$event_name"
  ) >/dev/null 2>&1 &
  hook_pid=$!

  (
    /bin/sleep "$EXTERNAL_HOOK_TIMEOUT_SECONDS"
    /bin/kill "$hook_pid" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  watchdog_pid=$!

  wait "$hook_pid" 2>/dev/null || true
  /bin/kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
}

emit_alert() {
  alert_kind="$1"

  case "$alert_kind" in
    approval)
      event_name="approval_required"
      title="Codex needs attention"
      message="Approval required."
      ;;
    complete)
      event_name="task_completed"
      title="Codex task finished"
      message="A long-running task has ended."
      ;;
    *) return 0 ;;
  esac

  project="$(project_label)" || project=""
  if [ -n "$project" ]; then
    title="$title · $project"
  fi

  local_enabled=0
  if delivery_enabled local "$event_name"; then
    local_enabled=1
  fi

  if [ "${CODEX_SOUND_ALERTS_TEST_MODE:-}" = "1" ]; then
    if [ "$local_enabled" = "1" ]; then
      record_test_event "sound:$alert_kind"
      if [ "${CODEX_SOUND_ALERTS_TEST_NOTIFICATION_FAILURE:-}" != "1" ]; then
        record_test_event "notification:$alert_kind"
      fi
    fi
    run_external_hook "$event_name" "$title" "$message" "$project"
    return 0
  fi

  if [ "$local_enabled" = "1" ]; then
    /usr/bin/osascript \
      -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' \
      "$title" "$message" >/dev/null 2>&1 || true

    case "$alert_kind" in
      approval)
        /usr/bin/afplay -v 2.0 /System/Library/Sounds/Ping.aiff >/dev/null 2>&1 || true
        ;;
      complete)
        /usr/bin/afplay -v 2.0 /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 || true
        ;;
    esac
  fi

  run_external_hook "$event_name" "$title" "$message" "$project"
}

case "$ACTION" in
  approval)
    emit_alert approval
    ;;
  start)
    [ -n "${PLUGIN_DATA:-}" ] || exit 0
    STATE_FILE="$(state_path)" || exit 0
    STATE_DIR="$(/usr/bin/dirname "$STATE_FILE")"
    /bin/mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
    /usr/bin/find "$STATE_DIR" -type f -name '*.started' -mtime +7 -delete 2>/dev/null || true
    [ -f "$STATE_FILE" ] && exit 0
    NOW="$(/bin/date +%s)" || exit 0
    TEMP_FILE="${STATE_FILE}.$$"
    printf '%s\n' "$NOW" >"$TEMP_FILE" 2>/dev/null || exit 0
    /bin/mv -f "$TEMP_FILE" "$STATE_FILE" 2>/dev/null || /bin/rm -f "$TEMP_FILE"
    ;;
  stop)
    [ -n "${PLUGIN_DATA:-}" ] || exit 0
    STATE_FILE="$(state_path)" || exit 0
    [ -f "$STATE_FILE" ] || exit 0
    STARTED_AT="$(/bin/cat "$STATE_FILE" 2>/dev/null || true)"
    /bin/rm -f "$STATE_FILE" 2>/dev/null || true
    case "$STARTED_AT" in
      ''|*[!0-9]*) exit 0 ;;
    esac
    NOW="$(/bin/date +%s)" || exit 0
    ELAPSED=$((NOW - STARTED_AT))
    if [ "$ELAPSED" -ge "$THRESHOLD_SECONDS" ]; then
      emit_alert complete
    fi
    ;;
esac

exit 0
