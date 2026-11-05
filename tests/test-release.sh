#!/usr/bin/env bash
# A package whose source lives in another organization (big-comm/bigrecorder
# built for BigLinux) gets no GitHub release: the pipeline's token cannot write
# there, and the release once failed with HTTP 403 after the package was
# already published.
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../scripts/publish-package.sh

# The functions under test, without running the script's main.
functions=$(grep -E '^(log|die)\(\) \{.*\}$' "$script")
functions+=$'\n'$(awk '
    /^(require_value|release_repository|publish_github_release)\(\) \{/ {keep = 1}
    keep {print}
    keep && /^\}/ {keep = 0}
' "$script")

fail=0
check() {  # check NAME EXPECTED ACTUAL
    if [[ $2 == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: expected [$2], got [$3]"; fail=1; fi
}

run() {  # run SOURCE_URL [RELEASE_REPOSITORY]; prints the release created, then the status
    SOURCE_URL=$1 RELEASE_REPOSITORY=${2:-} bash -c '
        eval "$1"
        GITHUB_REPOSITORY=biglinux/build-package GH_TOKEN=x
        PACKAGE_NAME=pkg PACKAGE_VERSION=1:26.11.05-2322 PACKAGES=(/tmp/pkg.pkg.tar.zst)
        gh() {
            [[ $1 == release && $2 == view ]] && return 1
            if [[ $1 == release && $2 == create ]]; then
                while (($#)); do [[ $1 == --repo ]] && printf "created %s\n" "$2" >&2; shift; done
            fi
            return 0
        }
        prepare_release_assets() { RELEASE_TMPDIR=/nonexistent; }
        tg_send() { :; }; tg_package() { :; }; tg_branch() { :; }
        tg_date() { :; }; tg_clock() { :; }; tg_actor() { :; }; tg_footer() { :; }
        publish_github_release >/dev/null
        echo "status=$?" >&2
    ' _ "$functions" 2>&1 | paste -sd' '
}

check 'big-comm source: no release, no error' \
    'status=0' "$(run https://github.com/big-comm/bigrecorder)"
check 'biglinux source: release in its own repository' \
    'created biglinux/bigrecorder status=0' "$(run https://github.com/biglinux/bigrecorder)"
check 'explicit release repository is honored' \
    'created big-comm/bigrecorder status=0' \
    "$(run https://github.com/big-comm/bigrecorder big-comm/bigrecorder)"

((fail == 0)) && echo 'all passed'
exit "$fail"
