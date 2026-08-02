#!/usr/bin/env bash
set -Eeuo pipefail

[[ -n ${TELEGRAM_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]] || exit 0

html_escape() {
    local value=$1
    value=${value//&/&amp;}
    value=${value//</&lt;}
    value=${value//>/&gt;}
    printf '%s' "$value"
}

status=${1:-unknown}
package=$(html_escape "${2:-unknown}")
branch=$(html_escape "${3:-unknown}")
url="https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

case "$status" in
    success) icon='✅'; title='Package published successfully' ;;
    build-success) icon='✅'; title='Package built successfully' ;;
    build-failure) icon='❌'; title='Package build failed' ;;
    publish-failure) icon='❌'; title='Package publication failed' ;;
    *) icon='ℹ️'; title='Package workflow finished' ;;
esac

message="${icon} <b>${title}</b>
<b>Package:</b> <code>${package}</code>
<b>Branch:</b> <code>${branch}</code>
<b>Run:</b> <a href=\"${url}\">#${GITHUB_RUN_NUMBER}</a>"

curl --fail --silent --show-error \
    --request POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" \
    --data-urlencode 'parse_mode=HTML' >/dev/null
