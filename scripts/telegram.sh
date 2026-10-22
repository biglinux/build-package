#!/usr/bin/env bash
# Telegram messages in the same format as big-comm/build-package, one per build.
# Sourced by notify.sh and publish-package.sh. Without TELEGRAM_TOKEN and
# TELEGRAM_CHAT_ID every function is a no-op, and a Telegram failure never
# fails the pipeline.

tg_escape() {
    local value=$1
    value=${value//&/&amp;}
    value=${value//</&lt;}
    value=${value//>/&gt;}
    printf '%s' "$value"
}

# One message per build: the first one is sent, every later step edits it
# (TELEGRAM_MESSAGE_ID, passed from job to job), so the chat shows the build's
# current step instead of four messages. Its id goes to the step output
# telegram_message_id. A message that cannot be edited is sent anew.
tg_send() {
    local message=$1
    # Same text in the log, without the HTML tags.
    # shellcheck disable=SC2001  # a regex, not a fixed string
    sed "s/<[^>]*>//g" <<< "$message"
    [[ -n ${TELEGRAM_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]] || return 0
    local answer id
    if [[ ${TELEGRAM_MESSAGE_ID:-} =~ ^[0-9]+$ ]]; then
        answer=$(tg_call editMessageText "message_id=${TELEGRAM_MESSAGE_ID}" "$message")
        # Same text as before is not an error: the message already shows it.
        [[ $answer == *'"ok":true'* || $answer == *'message is not modified'* ]] && return 0
        tg_warn 'not edited, sending it as a new message' "$answer"
    fi
    answer=$(tg_call sendMessage '' "$message")
    if [[ $answer != *'"ok":true'* ]]; then
        tg_warn 'not sent' "$answer"
        return 0
    fi
    id=$(sed -n 's/.*"message_id":\([0-9]*\).*/\1/p' <<< "$answer" | head -1)
    if [[ -n $id ]]; then
        TELEGRAM_MESSAGE_ID=$id
        [[ -n ${GITHUB_OUTPUT:-} ]] && echo "telegram_message_id=$id" >> "$GITHUB_OUTPUT"
    fi
    return 0
}

# tg_call METHOD [extra field] TEXT -> the API answer (JSON, or curl's error).
tg_call() {
    local method=$1 extra=$2 text=$3
    local -a fields=(--data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"
                     --data-urlencode "text=${text}"
                     --data-urlencode 'parse_mode=HTML'
                     --data-urlencode 'disable_web_page_preview=true')
    [[ -n $extra ]] && fields+=(--data-urlencode "$extra")
    curl --silent --show-error --max-time 20 \
        --request POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/${method}" \
        "${fields[@]}" 2>&1 || true
}

# The API answers errors with a JSON description: show it.
tg_warn() {
    printf '::warning::Telegram message %s: %s\n' "$1" \
        "$(sed -n 's/.*"description":"\([^"]*\)".*/\1/p' <<< "$2" | head -1)" >&2
}

tg_header() {
    printf '<b>Job:</b> <code>#%s</code>\n<b>Workflow:</b> <code>build-package/action.yml</code>' \
        "${GITHUB_RUN_NUMBER:-?}"
}

tg_time() {
    date -d "@$1" +'%Y-%m-%d %H:%M:%S'
}
