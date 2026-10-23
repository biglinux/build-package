#!/usr/bin/env bash
# Telegram notifications of the package pipeline, in the big-comm format:
#   notify.sh start               [step 1/4] starting package creation
#   notify.sh finish STATUS       [step 4/4] finished, or the failure alert
# Steps 2/4 and 3/4 are sent by publish-package.sh.
set -Eeuo pipefail

# shellcheck source=scripts/telegram.sh
source "$(dirname "${BASH_SOURCE[0]}")/telegram.sh"

package=$(tg_escape "${PACKAGE_NAME:-unknown}")

last_commit_message() {
    local url=${SOURCE_URL:-} ref=${SOURCE_BRANCH:-HEAD} hash tmp
    [[ $url =~ ^https://[^[:space:]]+$ ]] || return 0
    hash=$(git ls-remote "$url" "$ref" 2>/dev/null | awk 'NR == 1 {print $1}') || return 0
    [[ $hash =~ ^[0-9a-f]{40}$ ]] || return 0
    tmp=$(mktemp -d)
    if git -C "$tmp" init -q && git -C "$tmp" fetch -q --depth=1 "$url" "$hash" 2>/dev/null; then
        git -C "$tmp" log -1 --format=%B FETCH_HEAD | sed '/^$/d' | head -5
    fi
    rm -rf "$tmp"
}

# owner/repository of the source, linked to it.
source_link() {
    local url=${SOURCE_URL:-}
    [[ $url =~ ^https://github\.com/(.+)$ ]] || { tg_escape "${url:-unknown}"; return; }
    tg_link "$url" "${BASH_REMATCH[1]%.git}"
}

# testing (dev-talesam): the type, and the source branch when there is one.
branch_label() {
    local label=${BRANCH_TYPE:-unknown}
    [[ -n ${SOURCE_BRANCH:-} ]] && label+=" (${SOURCE_BRANCH})"
    printf '%s' "$label"
}

start() {
    local commit
    commit=$(last_commit_message || true)
    tg_send "🏁 <b>[step 1/4] build-package - STARTING PACKAGE CREATION</b>
$(tg_header)
<b>Name:</b> ${package}
<b>Commit:</b> $(tg_escape "${commit:-unavailable}")
<b>Source:</b> $(source_link)
<b>Started/Triggered by:</b> $(tg_user "${GITHUB_ACTOR:-?}")/$(tg_user "${GITHUB_TRIGGERING_ACTOR:-?}")
<b>Branch:</b> $(tg_escape "$(branch_label)")"
}

finish() {
    local status=$1 run_url
    run_url="https://github.com/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

    if [[ $status != success && $status != build-success ]]; then
        tg_send "🚨 <b>FAILED to create package:</b>
<b>Job:</b> $(tg_link "${run_url}" "#${GITHUB_RUN_NUMBER:-?}")
<b>Package:</b> ${package}
<b>Branch:</b> $(tg_escape "$(branch_label)")
<b>Error URL:</b> <a href='${run_url}'>${run_url}</a>"
        return
    fi

    local start end duration hours minutes seconds files branch
    start=${STARTED_AT:-}
    [[ $start =~ ^[0-9]+$ ]] || start=$(date +%s)
    end=$(date +%s)
    duration=$((end - start))
    hours=$((duration / 3600))
    minutes=$(((duration % 3600) / 60))
    seconds=$((duration % 60))
    branch=${PUBLISHED_BRANCH:-${BRANCH_TYPE:-unknown}}
    files=${PUBLISHED_FILES:-${PACKAGE_NAME:-unknown}}

    tg_send "🏆 <b>[step 4/4] build-package - FINISHED AT 🕒:</b> <code>${hours}h ${minutes}m ${seconds}s</code>
$(tg_header)
<b>Package:</b> $(tg_escape "${branch,,}/${files}")
<b>Start:</b> <code>$(tg_time "$start")</code>
<b>End:</b> <code>$(tg_time "$end")</code>
<b>Duration:</b> <code>${hours}h ${minutes}m ${seconds}s</code>"
}

case ${1:-} in
    start) start ;;
    finish) finish "${2:-unknown}" ;;
    *) echo "usage: $0 start | finish STATUS" >&2; exit 2 ;;
esac
