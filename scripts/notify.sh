#!/usr/bin/env bash
# Telegram notifications of the package pipeline, in the big-comm format:
#   notify.sh start               [step 1/4] starting package creation
#   notify.sh finish STATUS       [step 4/4] package ready, or the failure alert
# Steps 2/4 and 3/4 are sent by publish-package.sh.
set -Eeuo pipefail

# shellcheck source=scripts/telegram.sh
source "$(dirname "${BASH_SOURCE[0]}")/telegram.sh"

package=${PACKAGE_NAME:-unknown}

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

start() {
    local commit now
    commit=$(last_commit_message || true)
    now=$(date +%s)
    tg_send "🏁 <b>[step 1/4] STARTING PACKAGE CREATION</b>
$(tg_package "$package")
$(tg_branch "${BRANCH_TYPE:-unknown}" "${SOURCE_BRANCH:-}")
📝 <b>Commit:</b> <i>$(tg_escape "${commit:-unavailable}")</i>
🔗 <b>Source:</b> <code>$(tg_escape "${SOURCE_URL:-unknown}")</code>
$(tg_actor)
📅 <b>Date:</b> <code>$(tg_date "$now")</code>
🕒 <b>Time:</b> <code>$(tg_clock "$now")</code>
$(tg_footer)"
}

# The step a failed build stopped at, from the final status.
failed_step() {
    case $1 in
        build-failure) printf 'building the package' ;;
        publish-failure) printf 'publishing the package' ;;
    esac
}

finish() {
    local status=$1

    if [[ $status != success && $status != build-success ]]; then
        local step
        step=$(failed_step "$status")
        tg_send "🚨 <b>FAILED TO CREATE PACKAGE</b>
$(tg_package "$package")
$(tg_branch "${BRANCH_TYPE:-unknown}" "${SOURCE_BRANCH:-}")${step:+
❌ <b>Step:</b> ${step}}
🔗 <b>Details:</b> $(tg_link "$(tg_run_url)" "#${GITHUB_RUN_NUMBER:-?}")
$(tg_actor)"
        return
    fi

    local start end duration hours minutes seconds branch files end_text
    start=${STARTED_AT:-}
    [[ $start =~ ^[0-9]+$ ]] || start=$(date +%s)
    end=$(date +%s)
    duration=$((end - start))
    hours=$((duration / 3600))
    minutes=$(((duration % 3600) / 60))
    seconds=$((duration % 60))
    branch=${PUBLISHED_BRANCH:-${BRANCH_TYPE:-unknown}}
    files=${PUBLISHED_FILES:-$package}
    # A build that crosses midnight ends on another day: say which.
    end_text=$(tg_clock "$end")
    [[ $(tg_date "$end") != "$(tg_date "$start")" ]] && end_text="$(tg_date "$end") $end_text"

    tg_send "🏆 <b>[step 4/4] PACKAGE READY</b>
$(tg_package "${files//,/, }")
$(tg_branch "${branch,,}")
📅 <b>Date:</b> <code>$(tg_date "$start")</code>
🕒 <b>Start:</b> <code>$(tg_clock "$start")</code>
🕓 <b>End:</b> <code>${end_text}</code>
⏱️ <b>Duration:</b> <code>${hours}h ${minutes}m ${seconds}s</code>
$(tg_footer)
$(tg_actor 'Built by')"
}

case ${1:-} in
    start) start ;;
    finish) finish "${2:-unknown}" ;;
    *) echo "usage: $0 start | finish STATUS" >&2; exit 2 ;;
esac
