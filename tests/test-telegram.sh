#!/usr/bin/env bash
# One Telegram message per build: tg_send sends the first and edits it after.
# A fake curl answers like the Bot API and records which method was called.
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
for arg; do
    case $arg in
        */sendMessage) method=sendMessage ;;
        */editMessageText) method=editMessageText ;;
        message_id=*) id=${arg#message_id=} ;;
    esac
done
echo "$method" >> "$CALLS"
case $method in
    sendMessage) echo '{"ok":true,"result":{"message_id":'"$NEXT_ID"',"chat":{"id":1}}}' ;;
    # EDIT_ANSWER is the answer about the message the build started with (7);
    # the one sent in its place edits fine.
    editMessageText) [[ $id == 7 ]] && echo "$EDIT_ANSWER" || echo '{"ok":true}' ;;
esac
FAKE
chmod +x "$work/bin/curl"

fail=0
check() {  # check NAME EXPECTED ACTUAL
    if [[ $2 == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: expected [$2], got [$3]"; fail=1; fi
}

run() {  # run MESSAGE_ID EDIT_ANSWER -> calls, then "id=<TELEGRAM_MESSAGE_ID>", output file
    : > "$work/calls"; : > "$work/output"
    PATH="$work/bin:$PATH" CALLS="$work/calls" NEXT_ID=42 EDIT_ANSWER=$2 \
        TELEGRAM_TOKEN=x TELEGRAM_CHAT_ID=1 TELEGRAM_MESSAGE_ID=$1 GITHUB_OUTPUT="$work/output" \
        bash -c 'source "$1"; tg_send "<b>step</b>" >/dev/null 2>&1; tg_send "<b>next</b>" >/dev/null 2>&1; echo "id=$TELEGRAM_MESSAGE_ID"' _ "$here/../scripts/telegram.sh"
}

out=$(run '' '{"ok":true}')
check 'the first message is sent, the next one edits it' 'sendMessage editMessageText' "$(paste -sd' ' "$work/calls")"
check 'its id is the step output' 'telegram_message_id=42' "$(cat "$work/output")"
check 'and the id the next call edits' 'id=42' "$out"

out=$(run 7 '{"ok":true,"result":{}}')
check 'a known id is edited, never a new message' 'editMessageText editMessageText' "$(paste -sd' ' "$work/calls")"
check 'no new id when only editing' '' "$(cat "$work/output")"

out=$(run 7 '{"ok":false,"description":"Bad Request: message to edit not found"}')
check 'a message that cannot be edited is sent anew, then that one is edited' \
    'editMessageText sendMessage editMessageText' "$(paste -sd' ' "$work/calls")"
check 'the new id is the step output' 'telegram_message_id=42' "$(cat "$work/output")"

out=$(run 7 '{"ok":false,"description":"Bad Request: message is not modified"}')
check 'the same text again is not a new message' 'editMessageText editMessageText' "$(paste -sd' ' "$work/calls")"

: > "$work/calls"
TELEGRAM_TOKEN='' TELEGRAM_CHAT_ID='' PATH="$work/bin:$PATH" CALLS="$work/calls" \
    bash -c 'source "$1"; tg_send "text" >/dev/null' _ "$here/../scripts/telegram.sh"
check 'without the secrets nothing is called' '' "$(cat "$work/calls")"

((fail == 0)) && echo && echo 'all passed'
exit "$fail"
