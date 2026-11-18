#!/usr/bin/env bash
# The Secure Boot key reaches the biglinux/big-kernel build alone, as a file
# only builduser reads, and is gone after makepkg.
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The functions under test, without running the script's main.
functions=$(awk '
    /^(is_secureboot_build|provide_secureboot_key|remove_secureboot_key)\(\) \{/ {keep = 1}
    /^SECUREBOOT_KEY_(REPOSITORY|DIR|FILE)=/ {print}
    keep {print}
    keep && /^\}/ {keep = 0}
' "$here/../scripts/build-package.sh")

fail=0
check() {  # check NAME EXPECTED ACTUAL
    if [[ $2 == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: expected [$2], got [$3]"; fail=1; fi
}

# run URL BUILD_ENV KEY: provide the key, report what is there, remove it.
run() {
    (
        eval "$functions"
        SECUREBOOT_KEY_DIR=$work/secureboot
        # Stand-ins for the script's helpers, called by the functions above.
        # shellcheck disable=SC2329
        {
            die() { echo refused; exit 0; }
            log() { :; }
            as_root() { "$@"; }
            as_builduser() { "$@"; }
            install() { mkdir -m 0700 "${@: -1}"; }  # no builduser here
        }
        # shellcheck disable=SC2034  # read by the functions under test
        SOURCE_URL=$1 BUILD_ENV=$2
        provide_secureboot_key "$3"
        if [[ -n $SECUREBOOT_KEY_FILE ]]; then
            printf '%s %s|' "$(stat -c %a "$SECUREBOOT_KEY_FILE")" "$(cat "$SECUREBOOT_KEY_FILE")"
            remove_secureboot_key
            [[ -e $SECUREBOOT_KEY_DIR ]] && echo left-behind || echo removed
        else
            echo none
        fi
    )
}

check "the kernel build gets the key, then loses it" \
    "600 KEY|removed" "$(run https://github.com/biglinux/big-kernel testing KEY)"
check "the same with .git" \
    "600 KEY|removed" "$(run https://github.com/biglinux/big-kernel.git stable KEY)"
check "no key in the workflow: nothing" \
    "none" "$(run https://github.com/biglinux/big-kernel testing '')"
check "another package refuses a key that reached it" \
    "refused" "$(run https://github.com/biglinux/big-mesa testing KEY)"
check "a look-alike repository refuses it" \
    "refused" "$(run https://github.com/biglinux/big-kernel-fork testing KEY)"
check "an AUR build refuses it" \
    "refused" "$(run https://github.com/biglinux/big-kernel aur KEY)"
check "another package without a key: nothing" \
    "none" "$(run https://github.com/biglinux/big-mesa testing '')"

exit "$fail"
