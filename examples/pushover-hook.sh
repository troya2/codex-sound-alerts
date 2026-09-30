#!/bin/sh

# Copy this file to ~/.config/codex-sound-alerts/external-hook, make it
# executable, and create ~/.config/codex-sound-alerts/pushover.json with:
# {"user":"YOUR_USER_KEY","token":"YOUR_APPLICATION_TOKEN"}

set -u

CONFIG_PATH="${HOME:-}/.config/codex-sound-alerts/pushover.json"
PAYLOAD="$(/bin/cat 2>/dev/null || true)"

[ -f "$CONFIG_PATH" ] || exit 0

config_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$CONFIG_PATH" 2>/dev/null
}

payload_value() {
  printf '%s' "$PAYLOAD" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}

USER_KEY="$(config_value user)" || exit 0
APP_TOKEN="$(config_value token)" || exit 0
TITLE="$(payload_value title)" || exit 0
MESSAGE="$(payload_value message)" || exit 0

[ -n "$USER_KEY" ] && [ -n "$APP_TOKEN" ] || exit 0

/usr/bin/curl --silent --show-error --fail --max-time 2 \
  --form-string "token=$APP_TOKEN" \
  --form-string "user=$USER_KEY" \
  --form-string "title=$TITLE" \
  --form-string "message=$MESSAGE" \
  https://api.pushover.net/1/messages.json \
  >/dev/null 2>&1 || true

exit 0
