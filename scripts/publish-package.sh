#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
is_true() { [[ ${1,,} == true ]]; }

require_value() {
    local name=$1 value=${2-}
    [[ -n $value ]] || die "$name is required"
}

validate_boolean() {
    [[ ${1,,} == true || ${1,,} == false ]] || die "$2 must be true or false"
}

validate_package_name() {
    local file=$1 base
    base=$(basename "$file")
    [[ $base =~ ^[A-Za-z0-9][A-Za-z0-9@._+:-]*-[A-Za-z0-9@._+:-]+-[A-Za-z0-9_]+\.pkg\.tar\.zst$ ]] || \
        die "Unsafe package filename: $base"
    [[ -f $file && ! -L $file ]] || die "Package must be a regular file: $base"
}

validate_archive_paths() {
    local file=$1 entry
    while IFS= read -r entry; do
        [[ $entry != /* ]] || die "Package contains an absolute path: $entry"
        [[ /$entry/ != */../* ]] || die "Package contains path traversal: $entry"
    done < <(tar -tf "$file")
}

archive_member() {
    local file=$1 wanted=$2

    tar -tf "$file" |
        awk -v plain="$wanted" -v dotted="./$wanted" \
            '$0 == plain || $0 == dotted {print; exit}'
}

pkginfo_field() {
    local content=$1 key=$2
    local -a values=()

    mapfile -t values < <(
        awk -F' = ' -v key="$key" '$1 == key {print substr($0, index($0, " = ") + 3)}' \
            <<< "$content"
    )
    ((${#values[@]} == 1)) || die ".PKGINFO must contain exactly one $key field"
    [[ -n ${values[0]} ]] || die ".PKGINFO contains an empty $key field"
    printf '%s\n' "${values[0]}"
}

validate_package_metadata() {
    local file=$1 base pkginfo_member pkginfo
    local pkgname pkgbase pkgver arch expected_filename required

    base=$(basename "$file")
    for required in .PKGINFO .BUILDINFO .MTREE; do
        [[ -n $(archive_member "$file" "$required") ]] || \
            die "$base does not contain $required"
    done

    pkginfo_member=$(archive_member "$file" .PKGINFO)
    pkginfo=$(tar -xOf "$file" "$pkginfo_member")
    pkgname=$(pkginfo_field "$pkginfo" pkgname)
    pkgbase=$(pkginfo_field "$pkginfo" pkgbase)
    pkgver=$(pkginfo_field "$pkginfo" pkgver)
    arch=$(pkginfo_field "$pkginfo" arch)

    [[ $pkgname =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]] || die "Unsafe pkgname: $pkgname"
    [[ $pkgbase == "$PACKAGE_NAME" ]] || \
        die "Package base '$pkgbase' does not match requested package '$PACKAGE_NAME'"
    [[ $pkgver =~ ^[A-Za-z0-9@._+:-]+$ ]] || die "Unsafe pkgver: $pkgver"
    [[ $arch =~ ^[A-Za-z0-9_]+$ ]] || die "Unsafe package architecture: $arch"

    expected_filename="${pkgname}-${pkgver}-${arch}.pkg.tar.zst"
    [[ $base == "$expected_filename" ]] || \
        die "Filename '$base' does not match package metadata '$expected_filename'"

    if [[ -z ${PACKAGE_VERSION:-} ]]; then
        PACKAGE_VERSION=$pkgver
    elif [[ $PACKAGE_VERSION != "$pkgver" ]]; then
        die "Split packages have different versions: $PACKAGE_VERSION and $pkgver"
    fi
}

cleanup() {
    if [[ -n ${GNUPGHOME:-} && -d $GNUPGHOME ]]; then
        gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
    fi
    rm -rf -- "${GNUPGHOME:-}" "${SSH_TMPDIR:-}" "${RELEASE_TMPDIR:-}"
}

setup_gpg() {
    require_value GPG_PRIVATE_KEY "${GPG_PRIVATE_KEY:-}"
    require_value GPG_PASSPHRASE "${GPG_PASSPHRASE:-}"

    export GNUPGHOME
    GNUPGHOME=$(mktemp -d)
    chmod 0700 "$GNUPGHOME"
    gpg --batch --import <<< "$GPG_PRIVATE_KEY"
}

sign_packages() {
    local package base
    for package in "${PACKAGES[@]}"; do
        base=$(basename "$package")
        log "Signing $base"
        rm -f -- "$package.sig"
        printf '%s' "$GPG_PASSPHRASE" |
            gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
                --detach-sign "$package"
        gpg --batch --verify "$package.sig" "$package"
        (
            cd "$PACKAGE_DIR"
            sha256sum "$base" "$base.sig" > "$base.sha256"
        )
    done
    (cd "$PACKAGE_DIR" && sha256sum ./*.pkg.tar.zst ./*.pkg.tar.zst.sig > SHA256SUMS)
}

setup_ssh() {
    require_value SSH_PRIVATE_KEY "${SSH_PRIVATE_KEY:-}"
    require_value SSH_KNOWN_HOSTS "${SSH_KNOWN_HOSTS:-}"
    require_value REPO_HOST "${REPO_HOST:-}"
    require_value REPO_USER "${REPO_USER:-}"
    require_value REPO_PORT "${REPO_PORT:-}"
    require_value REPO_DIR "${REPO_DIR:-}"

    [[ $REPO_PORT =~ ^[0-9]{1,5}$ ]] || die 'REPO_PORT must be numeric'
    ((10#$REPO_PORT >= 1 && 10#$REPO_PORT <= 65535)) || die 'REPO_PORT is out of range'
    [[ $REPO_USER =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die 'Invalid REPO_USER'
    [[ $REPO_HOST =~ ^[A-Za-z0-9.-]+$ ]] || die 'Invalid REPO_HOST'
    [[ $REPO_DIR =~ ^/[A-Za-z0-9._/-]+$ && /$REPO_DIR/ != */../* ]] || \
        die 'REPO_DIR must be a safe absolute path without spaces or ..'

    SSH_TMPDIR=$(mktemp -d)
    SSH_KEY_FILE="$SSH_TMPDIR/id_package_repo"
    SSH_HOSTS_FILE="$SSH_TMPDIR/known_hosts"
    printf '%s\n' "$SSH_PRIVATE_KEY" > "$SSH_KEY_FILE"
    printf '%s\n' "$SSH_KNOWN_HOSTS" > "$SSH_HOSTS_FILE"
    chmod 0600 "$SSH_KEY_FILE" "$SSH_HOSTS_FILE"

    SSH_CMD=(ssh -i "$SSH_KEY_FILE" -p "$REPO_PORT" \
        -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
        -o "UserKnownHostsFile=$SSH_HOSTS_FILE")
    RSYNC_SSH="ssh -i '$SSH_KEY_FILE' -p '$REPO_PORT' -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile='$SSH_HOSTS_FILE'"
}

repo_coordinates() {
    case "$BRANCH_TYPE" in
        stable) REPO_BRANCH=stable; DB_NAME=community-stable ;;
        testing) REPO_BRANCH=testing; DB_NAME=community-testing ;;
        extra|aur) REPO_BRANCH=extra; DB_NAME=community-extra ;;
        *) die "Invalid BRANCH_TYPE: $BRANCH_TYPE" ;;
    esac
    TARGET_DIR="${REPO_DIR%/}/$REPO_BRANCH/x86_64"
}

publish_to_repository() {
    setup_ssh
    repo_coordinates

    local incoming="${TARGET_DIR}/.incoming-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
    log "Uploading packages to staging directory: $incoming"
    "${SSH_CMD[@]}" "$REPO_USER@$REPO_HOST" mkdir -p -- "$incoming"

    rsync --archive --protect-args --chmod=F644 --rsh="$RSYNC_SSH" \
        "$PACKAGE_DIR"/*.pkg.tar.zst \
        "$PACKAGE_DIR"/*.pkg.tar.zst.sig \
        "$PACKAGE_DIR"/*.pkg.tar.zst.sha256 \
        "$REPO_USER@$REPO_HOST:$incoming/"

    if ! is_true "$UPDATE_DB"; then
        "${SSH_CMD[@]}" "$REPO_USER@$REPO_HOST" \
            bash -s -- "$incoming" "$TARGET_DIR" <<'REMOTE_NO_DB'
set -Eeuo pipefail
incoming=$1
target=$2
mkdir -p "$target"
exec 9>"$target/.publish.lock"
flock -x 9
find "$incoming" -maxdepth 1 -type f -exec mv -f -t "$target" -- {} +
rmdir "$incoming"
REMOTE_NO_DB
        return
    fi

    log "Updating repository database: $DB_NAME"
    "${SSH_CMD[@]}" "$REPO_USER@$REPO_HOST" \
        bash -s -- "$incoming" "$TARGET_DIR" "$DB_NAME" <<'REMOTE_PUBLISH'
set -Eeuo pipefail
incoming=$1
target=$2
db_name=$3

mkdir -p "$target"
exec 9>"$target/.publish.lock"
flock -x 9

mapfile -d '' incoming_packages < <(find "$incoming" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print0)
((${#incoming_packages[@]} > 0)) || { echo 'No package files received' >&2; exit 1; }

packages=()
for source in "${incoming_packages[@]}"; do
    packages+=("$target/$(basename "$source")")
done

find "$incoming" -maxdepth 1 -type f -exec mv -f -t "$target" -- {} +
rmdir "$incoming"

cd "$target"
repo-add --remove --wait-for-lock --prevent-downgrade --include-sigs \
    "${db_name}.db.tar.gz" "${packages[@]}"

# repo-add removes superseded packages. Remove detached metadata left behind.
find . -maxdepth 1 -type f \( -name '*.sig' -o -name '*.sha256' \) -print0 |
while IFS= read -r -d '' file; do
    base=${file%.sig}
    base=${base%.sha256}
    [[ -f $base ]] || rm -f -- "$file"
done
REMOTE_PUBLISH
}

release_repository() {
    if [[ -n ${RELEASE_REPOSITORY:-} ]]; then
        [[ $RELEASE_REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
            die 'Invalid RELEASE_REPOSITORY'
        printf '%s\n' "$RELEASE_REPOSITORY"
        return
    fi

    if [[ ${SOURCE_URL:-} =~ ^https://github\.com/(biglinux|big-comm|talesam)/([A-Za-z0-9_.-]+)(\.git)?$ ]]; then
        printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
    else
        printf '%s\n' "$GITHUB_REPOSITORY"
    fi
}

prepare_release_assets() {
    local package size
    RELEASE_TMPDIR=$(mktemp -d)
    cp -f "$PACKAGE_DIR"/*.sig "$PACKAGE_DIR"/*.sha256 "$PACKAGE_DIR/SHA256SUMS" "$RELEASE_TMPDIR/"

    for package in "${PACKAGES[@]}"; do
        size=$(stat -c %s "$package")
        if ((size > 1900 * 1024 * 1024)); then
            log "Splitting $(basename "$package") for GitHub release"
            split --bytes=1900M --numeric-suffixes=1 --suffix-length=3 \
                "$package" "$RELEASE_TMPDIR/$(basename "$package").part-"
        else
            cp -f "$package" "$RELEASE_TMPDIR/"
        fi
    done
}

publish_github_release() {
    require_value GH_TOKEN "${GH_TOKEN:-}"
    command -v gh >/dev/null 2>&1 || die 'GitHub CLI is required'

    local repository tag
    repository=$(release_repository)
    tag=$PACKAGE_VERSION
    prepare_release_assets

    log "Publishing GitHub release $repository@$tag"
    if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
        gh release upload "$tag" "$RELEASE_TMPDIR"/* --clobber --repo "$repository"
    else
        gh release create "$tag" "$RELEASE_TMPDIR"/* \
            --repo "$repository" \
            --title "$PACKAGE_NAME $PACKAGE_VERSION" \
            --generate-notes \
            --notes "Built by BigLinux package pipeline from ${SOURCE_URL:-unknown source}."
    fi

    gh api --method POST "repos/$repository/dispatches" \
        -f event_type=windows-msi-build \
        -f "client_payload[tag_name]=$tag" >/dev/null 2>&1 || true
}

main() {
    : "${ARTIFACT_DIR:=$GITHUB_WORKSPACE/artifact}"
    : "${PACKAGE_DIR:=$ARTIFACT_DIR/packages}"
    : "${PUBLISH_GITHUB:=true}"
    : "${PUSH_TO_REPO:=true}"
    : "${UPDATE_DB:=true}"

    require_value PACKAGE_NAME "${PACKAGE_NAME:-}"
    require_value BRANCH_TYPE "${BRANCH_TYPE:-}"
    [[ $PACKAGE_NAME =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]] || die 'Invalid PACKAGE_NAME'
    [[ $BRANCH_TYPE =~ ^(stable|testing|extra|aur)$ ]] || die 'Invalid BRANCH_TYPE'
    validate_boolean "$PUBLISH_GITHUB" PUBLISH_GITHUB
    validate_boolean "$PUSH_TO_REPO" PUSH_TO_REPO
    validate_boolean "$UPDATE_DB" UPDATE_DB
    [[ -d $PACKAGE_DIR ]] || die "Package directory not found: $PACKAGE_DIR"

    mapfile -d '' PACKAGES < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print0 | sort -z)
    ((${#PACKAGES[@]} > 0)) || die 'No package artifact found'

    command -v tar >/dev/null 2>&1 || die 'tar is required'
    local package
    PACKAGE_VERSION=
    for package in "${PACKAGES[@]}"; do
        validate_package_name "$package"
        validate_archive_paths "$package"
        validate_package_metadata "$package"
    done

    trap cleanup EXIT
    setup_gpg
    sign_packages

    is_true "$PUSH_TO_REPO" && publish_to_repository
    if is_true "$PUBLISH_GITHUB" && [[ $BRANCH_TYPE != testing && $BRANCH_TYPE != aur ]]; then
        publish_github_release
    fi

    log 'Publication completed successfully'
}

main "$@"
