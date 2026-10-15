#!/usr/bin/env bash
# Telegram messages in the same format as big-comm/build-package.
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

tg_send() {
    local message=$1
    # Same text in the log, without the HTML tags.
    # shellcheck disable=SC2001  # a regex, not a fixed string
    sed "s/<[^>]*>//g" <<< "$message"
    [[ -n ${TELEGRAM_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]] || return 0
    local answer
    answer=$(curl --silent --show-error --max-time 20 \
        --request POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --data-urlencode 'parse_mode=HTML' \
        --data-urlencode 'disable_web_page_preview=true' 2>&1) || true
    # The API answers HTTP errors with a JSON description: show it.
    if [[ $answer != *'"ok":true'* ]]; then
        printf '::warning::Telegram message not sent: %s\n' \
            "$(sed -n 's/.*"description":"\([^"]*\)".*/\1/p' <<< "$answer" | head -1)" >&2
    fi
    return 0
}

tg_header() {
    printf '<b>Job:</b> <code>#%s</code>\n<b>Workflow:</b> <code>build-package/action.yml</code>' \
        "${GITHUB_RUN_NUMBER:-?}"
}

tg_time() {
    date -d "@$1" +'%Y-%m-%d %H:%M:%S'
}
