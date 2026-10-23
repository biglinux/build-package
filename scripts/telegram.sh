#!/usr/bin/env bash
# Telegram messages in the same format as big-comm/build-package, one per build.
# Sourced by notify.sh and publish-package.sh. Without TELEGRAM_TOKEN and
# TELEGRAM_CHAT_ID every function is a no-op, and a Telegram failure never
# fails the pipeline.

tg_escape() {
    local value=$1
    # Quoted replacements: since bash 5.2 an unquoted & in the replacement
    # stands for the matched text, which turned &lt; into <lt; and broke the HTML.
    value=${value//&/"&amp;"}
    value=${value//</"&lt;"}
    value=${value//>/"&gt;"}
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
                     --data-urlencode 'disable_web_page_preview=true'
                     --data-urlencode 'link_preview_options={"is_disabled":true}')
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

# tg_link URL TEXT -> a link; both are escaped, the URL also for the attribute.
tg_link() {
    local url=$1 text=$2
    url=$(tg_escape "$url")
    printf '<a href="%s">%s</a>' "${url//\"/"&quot;"}" "$(tg_escape "$text")"
}

# tg_user LOGIN -> the GitHub account as a link to its profile.
tg_user() {
    tg_link "https://github.com/$1" "$1"
}

tg_run_url() {
    printf 'https://github.com/%s/actions/runs/%s' "${GITHUB_REPOSITORY:-}" "${GITHUB_RUN_ID:-}"
}

# Every line of a message starts with its icon. Each step repeats the package,
# its branch and who triggered the build, since the message shows only the
# build's current step.

# tg_branch_icon BRANCH -> the icon of the repository branch.
tg_branch_icon() {
    case ${1,,} in
        testing) printf '🧪' ;;
        stable) printf '✅' ;;
        extra) printf '🧩' ;;
        priority) printf '🚀' ;;
        aur) printf '🐧' ;;
        *) printf '❔' ;;
    esac
}

# tg_package NAME -> the package line.
tg_package() {
    printf '📦 <b>Package:</b> %s' "$(tg_escape "$1")"
}

# tg_branch BRANCH [SOURCE BRANCH] -> "🧪 Branch: testing (dev-talesam)".
tg_branch() {
    local label=$1
    [[ -n ${2:-} ]] && label+=" ($2)"
    printf '%s <b>Branch:</b> %s' "$(tg_branch_icon "$1")" "$(tg_escape "$label")"
}

# tg_actor [LABEL] -> the GitHub account that triggered the build.
tg_actor() {
    printf '👤 <b>%s:</b> <code>%s</code>' "${1:-Triggered by}" \
        "$(tg_escape "${GITHUB_TRIGGERING_ACTOR:-${GITHUB_ACTOR:-unknown}}")"
}

# tg_footer -> the run and the workflow, as links.
tg_footer() {
    printf '⚙️ <b>Job:</b> %s\n📄 <b>Workflow:</b> %s' \
        "$(tg_link "$(tg_run_url)" "#${GITHUB_RUN_NUMBER:-?}")" \
        "$(tg_link "https://github.com/${GITHUB_REPOSITORY:-}/blob/main/action.yml" build-package/action.yml)"
}

# tg_size BYTES -> "1.2 MB".
tg_size() {
    awk -v bytes="$1" 'BEGIN {
        split("B KB MB GB", unit); i = 1
        while (bytes >= 1024 && i < 4) { bytes /= 1024; i++ }
        printf(i == 1 ? "%d %s" : "%.1f %s", bytes, unit[i])
    }'
}

tg_date() {
    date -d "@$1" +'%Y-%m-%d'
}

tg_clock() {
    date -d "@$1" +'%H:%M:%S'
}
