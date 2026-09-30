#!/bin/sh

# Codex passes hook details on stdin. Only IDs and timestamps are persisted.
set -u
umask 077

ACTION="${1:-}"
THRESHOLD_SECONDS=60
EXTERNAL_HOOK_TIMEOUT_SECONDS=3
PAYLOAD="$(/bin/cat 2>/dev/null || true)"

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

run_external_hook() {
  event_name="$1"
  title="$2"
  message="$3"
  hook_path="${CODEX_SOUND_ALERTS_EXTERNAL_HOOK:-${HOME:-}/.config/codex-sound-alerts/external-hook}"

  [ -n "$hook_path" ] && [ -f "$hook_path" ] && [ -x "$hook_path" ] || return 0

  occurred_at="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  event_json="{\"version\":1,\"event\":\"$event_name\",\"title\":\"$title\",\"message\":\"$message\",\"occurred_at\":\"$occurred_at\"}"

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

  if [ "${CODEX_SOUND_ALERTS_TEST_MODE:-}" = "1" ]; then
    record_test_event "sound:$alert_kind"
    if [ "${CODEX_SOUND_ALERTS_TEST_NOTIFICATION_FAILURE:-}" != "1" ]; then
      record_test_event "notification:$alert_kind"
    fi
    run_external_hook "$event_name" "$title" "$message"
    return 0
  fi

  case "$alert_kind" in
    approval)
      /usr/bin/osascript -e 'display notification "Approval required." with title "Codex needs attention"' >/dev/null 2>&1 || true
      /usr/bin/afplay -v 2.0 /System/Library/Sounds/Ping.aiff >/dev/null 2>&1 || true
      ;;
    complete)
      /usr/bin/osascript -e 'display notification "A long-running task has ended." with title "Codex task finished"' >/dev/null 2>&1 || true
      /usr/bin/afplay -v 2.0 /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 || true
      ;;
  esac

  run_external_hook "$event_name" "$title" "$message"
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
