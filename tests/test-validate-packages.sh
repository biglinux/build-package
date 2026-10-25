#!/usr/bin/env bash
# validate_packages checks what makepkg produced by each package's own
# .PKGINFO. A date-stamped PKGBUILD (pkgrel=$(date +%H%M)) once failed every
# build whose minute changed before the check: the check evaluated the
# PKGBUILD again and expected a newer version than the one just built.
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The functions under test, without running the script's main.
functions=$(awk '
    /^(die|pkginfo_value|validate_packages)\(\) \{/ {keep = 1}
    keep {print}
    keep && /^\}/ {keep = 0}
' "$here/../scripts/build-package.sh")

fail=0
check() {  # check NAME EXPECTED ACTUAL
    if [[ $2 == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1: expected [$2], got [$3]"; fail=1; fi
}

package() {  # package DIR FILE_NAME PKGNAME PKGVER ARCH
    local dir=$1 tmp
    tmp=$(mktemp -d "$work/pkg.XXXXXX")
    printf 'pkgname = %s\npkgbase = base\npkgver = %s\narch = %s\n' "$3" "$4" "$5" > "$tmp/.PKGINFO"
    tar --zstd -cf "$dir/$2" -C "$tmp" .PKGINFO
}

run() {  # run DECLARED_PKGNAMES... -- packages in $work/out; prints "pass" or the error
    local out
    out=$(PACKAGES_DIR="$work/out" DECLARED="$*" bash -c '
        eval "$1"
        # The PKGBUILD as makepkg --printsrcinfo shows it; namcap is not under test.
        as_builduser_in() { printf "pkgbase = base\n"; for n in $DECLARED; do printf "pkgname = %s\n" "$n"; done; }
        namcap() { :; }
        validate_packages /nonexistent && echo pass
    ' _ "$functions" 2>&1) || true
    printf '%s\n' "${out##*$'\n'}"
}

fresh() { rm -rf "$work/out"; mkdir "$work/out"; }

# The failed build: built at 03:11, checked at 03:12. Only what was built counts.
fresh
package "$work/out" big-driver-manager-cli-1:26.10.25-0311-any.pkg.tar.zst big-driver-manager-cli 1:26.10.25-0311 any
package "$work/out" biglinux-driver-manager-1:26.10.25-0311-any.pkg.tar.zst biglinux-driver-manager 1:26.10.25-0311 any
check "split package built across a minute change" pass "$(run big-driver-manager-cli biglinux-driver-manager)"

fresh
package "$work/out" big-driver-manager-cli-1:26.10.25-0311-any.pkg.tar.zst big-driver-manager-cli 1:26.10.25-0311 any
check "a declared package is missing" \
    "ERROR: Produced packages differ from the pkgname list of the PKGBUILD" \
    "$(run big-driver-manager-cli biglinux-driver-manager)"

fresh
package "$work/out" foo-1.0-1-any.pkg.tar.zst foo 1.0-1 any
package "$work/out" intruder-1.0-1-any.pkg.tar.zst intruder 1.0-1 any
check "a package the PKGBUILD does not declare" \
    "ERROR: Produced packages differ from the pkgname list of the PKGBUILD" "$(run foo)"

fresh
package "$work/out" foo-2.0-1-any.pkg.tar.zst foo 1.0-1 any
check "file name does not match .PKGINFO" \
    "ERROR: foo-2.0-1-any.pkg.tar.zst does not match its .PKGINFO (foo-1.0-1-any)" "$(run foo)"

fresh
package "$work/out" foo-1.0-1-any.pkg.tar.zst foo 1.0-1 any
package "$work/out" bar-1.0-2-any.pkg.tar.zst bar 1.0-2 any
check "split packages with different versions" \
    "ERROR: Split packages have different versions: 1.0-1 1.0-2 " "$(run foo bar)"

fresh
package "$work/out" foo-1.0-1-x86_64.pkg.tar.zst foo 1.0-1 x86_64
package "$work/out" foo-debug-1.0-1-x86_64.pkg.tar.zst foo-debug 1.0-1 x86_64
check "makepkg's -debug package is accepted" pass "$(run foo)"

fresh
check "nothing built" "ERROR: makepkg did not produce a package" "$(run foo)"

exit "$fail"
