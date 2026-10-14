#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo -- "$@"
    fi
}

as_builduser_in() {
    local directory=$1
    shift

    # The command is intentionally single-quoted so the inner Bash expands it.
    # shellcheck disable=SC2016
    runuser -u builduser -- env \
        HOME=/home/builduser \
        SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}" \
        BIGLINUX_BUILD_VERSION="${BIGLINUX_BUILD_VERSION:-}" \
        BIGLINUX_GIT_BRANCH="${BIGLINUX_GIT_BRANCH:-}" \
        bash -c 'directory=$1; shift; cd -- "$directory"; exec "$@"' \
        _ "$directory" "$@"
}

require_value() {
    local name=$1 value=${2-}
    [[ -n $value ]] || die "$name is required"
}

validate_enum() {
    local value=$1; shift
    local allowed
    for allowed in "$@"; do
        [[ $value == "$allowed" ]] && return 0
    done
    die "Invalid value '$value' (allowed: $*)"
}

strip_repo_sections() {
    local file=$1
    shift
    local sections
    sections="|$(IFS='|'; printf '%s' "$*")|"
    awk -v sections="$sections" '
        /^\[[^]]+\]$/ {
            name=$0
            gsub(/^\[|\]$/, "", name)
            skip=(index(sections, "|" name "|") > 0)
        }
        !skip { print }
    ' "$file" > "$file.tmp"
    as_root install -m 0644 "$file.tmp" "$file"
    rm -f "$file.tmp"
}

append_repo() {
    local name=$1 url=$2
    cat <<EOF_REPO | as_root tee -a /etc/pacman.conf >/dev/null

[$name]
SigLevel = PackageRequired
Server = $url
EOF_REPO
}

configure_repositories() {
    local branch=$1 manjaro_branch=$2 mirror=$3

    validate_enum "$manjaro_branch" stable testing unstable

    if [[ -z $mirror ]]; then
        mirror="https://repo.manjaro.org/repo/${manjaro_branch}/\$repo/\$arch"
    fi
    [[ $mirror =~ ^https://[^[:space:]]+$ ]] || \
        die 'PACMAN_MIRROR must be a single HTTPS URL without whitespace'

    log "Configuring Manjaro branch: $manjaro_branch"
    printf 'Server = %s\n' "$mirror" | as_root tee /etc/pacman.d/mirrorlist >/dev/null

    strip_repo_sections /etc/pacman.conf \
        community-stable community-testing community-extra \
        biglinux-stable biglinux-testing

    # Repository order is intentional: the target branch comes first and
    # stable repositories are only fallbacks where required.
    case "$branch" in
        stable)
            append_repo community-stable "https://repo.communitybig.org/stable/\$arch"
            append_repo biglinux-stable "https://repo.biglinux.com.br/stable/\$arch"
            ;;
        testing)
            append_repo community-testing "https://repo.communitybig.org/testing/\$arch"
            append_repo community-stable "https://repo.communitybig.org/stable/\$arch"
            append_repo biglinux-testing "https://repo.biglinux.com.br/testing/\$arch"
            append_repo biglinux-stable "https://repo.biglinux.com.br/stable/\$arch"
            ;;
        extra|aur)
            append_repo community-extra "https://repo.communitybig.org/extra/\$arch"
            append_repo community-testing "https://repo.communitybig.org/testing/\$arch"
            append_repo community-stable "https://repo.communitybig.org/stable/\$arch"
            append_repo biglinux-testing "https://repo.biglinux.com.br/testing/\$arch"
            append_repo biglinux-stable "https://repo.biglinux.com.br/stable/\$arch"
            ;;
    esac

    if [[ $branch == aur || $branch == extra ]]; then
        as_root sed -i '/^#\[multilib\]/,/^#Include/s/^#//' /etc/pacman.conf
    fi

    log 'Updating the complete rolling-release environment'
    as_root pacman -Syyu --needed --noconfirm --noprogressbar
    as_root pacman -S --needed --noconfirm --noprogressbar \
        base-devel git gnupg jq namcap rsync sudo
}

ensure_build_user() {
    if ! id builduser >/dev/null 2>&1; then
        as_root useradd --create-home --shell /bin/bash builduser
    fi

    as_root rm -rf /home/builduser/build /home/builduser/packages /home/builduser/sources
    as_root install -d -o builduser -g builduser -m 0755 \
        /home/builduser/build /home/builduser/packages /home/builduser/sources

    # makepkg --syncdeps and AUR helpers need pacman. This permission exists
    # only inside the disposable, secret-free build container.
    printf 'builduser ALL=(root) NOPASSWD: /usr/bin/pacman\n' | \
        as_root tee /etc/sudoers.d/biglinux-build-pacman >/dev/null
    as_root chmod 0440 /etc/sudoers.d/biglinux-build-pacman
}

configure_makepkg() {
    as_root sed -Ei \
        '/^[[:space:]#]*(PACKAGER|MAKEFLAGS|PKGDEST|SRCDEST|GPGKEY)=/d' \
        /etc/makepkg.conf

    cat <<EOF_MAKEPKG | as_root tee -a /etc/makepkg.conf >/dev/null
PACKAGER="BigLinux Build System <packages@biglinux.com.br>"
MAKEFLAGS="-j$(nproc)"
PKGDEST=/home/builduser/packages
SRCDEST=/home/builduser/sources
EOF_MAKEPKG
}

clone_source() {
    local target=$1
    local url=$SOURCE_URL

    if [[ $BUILD_ENV == aur ]]; then
        [[ $url =~ ^https://aur\.archlinux\.org/[A-Za-z0-9@._+-]+(\.git)?$ ]] || \
            die 'AUR_URL must point to https://aur.archlinux.org/<package>.git'

        local aur_name=${url#https://aur.archlinux.org/}
        aur_name=${aur_name%.git}
        [[ $aur_name == "$PACKAGE_NAME" ]] || \
            die "AUR URL package '$aur_name' does not match PACKAGE_NAME '$PACKAGE_NAME'"
    else
        [[ $url =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]] || \
            die 'SOURCE_URL must be an HTTPS GitHub repository URL'
    fi

    local clone_args=(--no-tags)
    if [[ -n ${SOURCE_BRANCH:-} ]]; then
        git check-ref-format --branch "$SOURCE_BRANCH" >/dev/null 2>&1 || \
            die 'Invalid source branch name'
        clone_args+=(--branch "$SOURCE_BRANCH" --single-branch)
    fi

    log "Cloning source: $url"
    if ! git clone "${clone_args[@]}" "$url" "$target"; then
        if [[ -n ${SOURCE_BRANCH:-} ]]; then
            die "Unable to clone requested branch '$SOURCE_BRANCH' from $url"
        fi
        die "Unable to clone source repository: $url"
    fi

    git -C "$target" rev-parse HEAD
}

select_pkgbuild_dir() {
    local source_dir=$1

    if [[ -n ${PKGBUILD_PATH:-} ]]; then
        [[ $PKGBUILD_PATH != /* && $PKGBUILD_PATH != *$'\n'* ]] || \
            die 'pkgbuild_path must be a relative path'
        [[ /$PKGBUILD_PATH/ != */../* ]] || die 'pkgbuild_path cannot contain ..'

        local requested source_root
        source_root=$(realpath "$source_dir")
        requested=$(realpath -m "$source_dir/$PKGBUILD_PATH")
        [[ $requested == "$source_root" || $requested == "$source_root"/* ]] || \
            die 'pkgbuild_path escapes the source repository'
        [[ -f $requested/PKGBUILD && ! -L $requested/PKGBUILD ]] || \
            die "PKGBUILD must be a regular non-symbolic-link file in $PKGBUILD_PATH"

        local pkgbuild_real
        pkgbuild_real=$(realpath "$requested/PKGBUILD")
        [[ $pkgbuild_real == "$source_root"/* ]] || \
            die 'PKGBUILD resolves outside the source repository'

        printf '%s\n' "$requested"
        return
    fi

    mapfile -t pkgbuilds < <(find "$source_dir" -type f -name PKGBUILD -print)
    ((${#pkgbuilds[@]} > 0)) || die 'No PKGBUILD found'
    ((${#pkgbuilds[@]} == 1)) || {
        printf 'Multiple PKGBUILDs found; set pkgbuild_path:\n' >&2
        printf '  %s\n' "${pkgbuilds[@]}" >&2
        exit 1
    }

    dirname "${pkgbuilds[0]}"
}

patch_testing_branch() {
    local pkgbuild=$1 branch=${NEW_BRANCH:-}
    [[ $BRANCH_TYPE == testing && -n $branch ]] || return 0
    [[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || die 'Invalid testing branch name'

    # Compatibility for existing BigLinux PKGBUILDs. New PKGBUILDs should
    # consume BIGLINUX_GIT_BRANCH directly instead of relying on this patch.
    python - "$pkgbuild" "$branch" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
branch = sys.argv[2]
text = path.read_text()
pattern = re.compile(
    r'(?P<url>git\+https://github\.com/(?:biglinux|big-comm)/[^\s"\']+?\.git)'
    r'(?:#(?:branch|tag)=[^\s"\']+)?'
)
new_text, count = pattern.subn(lambda m: f"{m.group('url')}#branch={branch}", text)
if count:
    path.write_text(new_text)
    print(f"Patched {count} BigLinux Git source URL(s) for branch {branch}")
else:
    print("No BigLinux Git source URL required patching")
PY
}

import_source_keys() {
    local pkgdir=$1 key
    local -a keys=()
    mapfile -t keys < <(
        as_builduser_in "$pkgdir" makepkg --printsrcinfo |
            awk -F'= ' '/^[[:space:]]*validpgpkeys = / {print $2}'
    )

    ((${#keys[@]} > 0)) || return 0
    for key in "${keys[@]}"; do
        [[ $key =~ ^[A-Fa-f0-9]{16,64}$ ]] || die "Invalid validpgpkeys value: $key"
        log "Importing source verification key: $key"
        runuser -u builduser -- env HOME=/home/builduser \
            gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key"
    done
}

install_aur_dependencies() {
    local pkgdir=$1
    local -a deps=()
    command -v yay >/dev/null 2>&1 || return 0

    mapfile -t deps < <(
        as_builduser_in "$pkgdir" makepkg --printsrcinfo |
            awk -F'= ' '
                /^[[:space:]]*(depends|makedepends|checkdepends) = / {
                    dep=$2
                    sub(/[<>=].*$/, "", dep)
                    if (dep != "") print dep
                }
            ' | sort -u
    )

    ((${#deps[@]} > 0)) || return 0
    log "Installing ${#deps[@]} declared dependencies with yay"
    runuser -u builduser -- env HOME=/home/builduser \
        yay -S --asdeps --needed --noconfirm \
        --answerclean None --answerdiff None "${deps[@]}"
}

validate_packages() {
    local pkgdir=$1 package
    local -a packages expected actual

    shopt -s nullglob
    packages=(/home/builduser/packages/*.pkg.tar.zst)
    ((${#packages[@]} > 0)) || die 'makepkg did not produce a package'

    mapfile -t expected < <(
        as_builduser_in "$pkgdir" makepkg --packagelist |
            sed 's#^.*/##' | sort -u
    )
    ((${#expected[@]} > 0)) || die 'PKGBUILD declared no package outputs'

    for package in "${packages[@]}"; do
        [[ -f $package && ! -L $package ]] || die "Invalid package output: $package"
        actual+=("$(basename "$package")")
        namcap "$package" || true
    done
    mapfile -t actual < <(printf '%s\n' "${actual[@]}" | sort -u)

    if ! diff -u \
        <(printf '%s\n' "${expected[@]}") \
        <(printf '%s\n' "${actual[@]}"); then
        die 'Produced package files differ from makepkg --packagelist'
    fi
}

write_metadata() {
    local source_commit=$1 pkgdir=$2
    local metadata_dir="$DIST_DIR/metadata"
    install -d "$DIST_DIR/packages" "$metadata_dir"

    cp -f /home/builduser/packages/*.pkg.tar.zst "$DIST_DIR/packages/"
    cp -f "$pkgdir/PKGBUILD" "$metadata_dir/PKGBUILD"
    as_builduser_in "$pkgdir" makepkg --printsrcinfo > "$metadata_dir/.SRCINFO"
    pacman -Q > "$metadata_dir/installed-packages.txt"
    (cd "$DIST_DIR/packages" && sha256sum ./*.pkg.tar.zst) > \
        "$metadata_dir/SHA256SUMS.unsigned"

    jq -n \
        --arg package_name "$PACKAGE_NAME" \
        --arg build_env "$BUILD_ENV" \
        --arg branch_type "$BRANCH_TYPE" \
        --arg source_url "$SOURCE_URL" \
        --arg source_commit "$source_commit" \
        --arg build_version "$BIGLINUX_BUILD_VERSION" \
        --arg started_at "$BUILD_STARTED_AT" \
        '{package_name:$package_name,build_env:$build_env,branch_type:$branch_type,source_url:$source_url,source_commit:$source_commit,build_version:$build_version,started_at:$started_at}' \
        > "$metadata_dir/build.json"
}

main() {
    : "${BUILD_ENV:=testing}"
    : "${BRANCH_TYPE:=$BUILD_ENV}"
    : "${MANJARO_BRANCH:=stable}"
    : "${PACMAN_MIRROR:=}"
    : "${SOURCE_BRANCH:=}"
    : "${NEW_BRANCH:=}"
    : "${PKGBUILD_PATH:=}"
    : "${AUR_COMMIT:=}"
    : "${AUR_PKGREL:=}"
    : "${DIST_DIR:=$GITHUB_WORKSPACE/dist}"

    require_value PACKAGE_NAME "${PACKAGE_NAME:-}"
    require_value SOURCE_URL "${SOURCE_URL:-}"
    [[ $PACKAGE_NAME =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]] || die 'Invalid package name'
    validate_enum "$BUILD_ENV" stable testing extra aur
    validate_enum "$BRANCH_TYPE" stable testing extra aur

    rm -rf "$DIST_DIR"
    configure_repositories "$BRANCH_TYPE" "$MANJARO_BRANCH" "$PACMAN_MIRROR"
    ensure_build_user
    configure_makepkg

    # Define the package build timestamp once, after the rolling update and
    # immediately before source preparation and compilation.
    export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(date -u +%s)}
    export BIGLINUX_BUILD_VERSION=${BIGLINUX_BUILD_VERSION:-$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y%m%d.%H%M)}
    export BUILD_STARTED_AT
    BUILD_STARTED_AT=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
    export BIGLINUX_GIT_BRANCH=${NEW_BRANCH:-${SOURCE_BRANCH:-}}

    local source_dir=/home/builduser/build/source
    as_root rm -rf "$source_dir"
    as_root install -d -o builduser -g builduser "$source_dir"
    as_root rmdir "$source_dir"

    local source_commit
    source_commit=$(runuser -u builduser -- env \
        HOME=/home/builduser BUILD_ENV="$BUILD_ENV" SOURCE_URL="$SOURCE_URL" \
        SOURCE_BRANCH="$SOURCE_BRANCH" PACKAGE_NAME="$PACKAGE_NAME" \
        bash -c "$(declare -f die log clone_source); clone_source '$source_dir'")
    source_commit=${source_commit##*$'\n'}

    # AUR only: Repo Management reviews what changed in the AUR before asking
    # for a build and sends the commit it reviewed -- build that one, not
    # whatever was pushed in the meantime.
    if [[ $BUILD_ENV == aur && -n $AUR_COMMIT ]]; then
        [[ $AUR_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "Invalid aur_commit: $AUR_COMMIT"
        runuser -u builduser -- git -C "$source_dir" checkout --quiet --detach "$AUR_COMMIT" ||
            die "The reviewed AUR commit $AUR_COMMIT is not in the AUR repository"
        source_commit=$AUR_COMMIT
        log "Building the reviewed AUR commit: $AUR_COMMIT"
    fi

    local pkgdir
    pkgdir=$(select_pkgbuild_dir "$source_dir")
    as_root chown -R builduser:builduser "$source_dir"
    patch_testing_branch "$pkgdir/PKGBUILD"

    # AUR only: rebuild the same AUR version (e.g. after the Python minor
    # version changed) as pkgrel 4.1, 4.2... so pacman upgrades machines that
    # already have the old build.
    if [[ $BUILD_ENV == aur && -n $AUR_PKGREL ]]; then
        [[ $AUR_PKGREL =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "Invalid aur_pkgrel: $AUR_PKGREL"
        grep -q '^pkgrel=' "$pkgdir/PKGBUILD" || die 'PKGBUILD has no pkgrel= line'
        log "Rebuild: pkgrel $(sed -n 's/^pkgrel=//p' "$pkgdir/PKGBUILD") -> $AUR_PKGREL"
        as_root sed -i "s/^pkgrel=.*/pkgrel=$AUR_PKGREL/" "$pkgdir/PKGBUILD"
    fi

    import_source_keys "$pkgdir"
    if [[ $BUILD_ENV == aur ]]; then
        install_aur_dependencies "$pkgdir"
        # Do not publish package files produced while resolving AUR dependencies.
        as_root find /home/builduser/packages -mindepth 1 -maxdepth 1 -delete
    fi

    log "Building $PACKAGE_NAME as unprivileged user"
    as_builduser_in "$pkgdir" makepkg \
        --cleanbuild --clean --syncdeps --noconfirm --noprogressbar --nosign

    namcap "$pkgdir/PKGBUILD" || true
    validate_packages "$pkgdir"
    write_metadata "$source_commit" "$pkgdir"

    log 'Unsigned build artifact created:'
    find "$DIST_DIR" -maxdepth 2 -type f -printf '  %P\n' | sort
}

main "$@"
