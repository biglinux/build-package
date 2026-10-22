# Community Package Build Action

This repository contains GitHub Actions workflows and a custom action for building, signing, and publishing Arch Linux and Manjaro packages for the BigLinux Community repository.

It supports packages maintained by BigLinux as well as packages obtained from the Arch User Repository (AUR). Both use the same pipeline so the build process remains consistent and easier to maintain.

## Table of Contents

1. [Overview](#overview)
2. [Package Pipeline](#package-pipeline)
3. [Workflows](#workflows)
   - [Build Package](#build-package)
   - [AUR Package Build](#aur-package-build)
   - [Reusable Package Pipeline](#reusable-package-pipeline)
   - [Validation](#validation)
4. [Custom Action and Scripts](#custom-action-and-scripts)
5. [Usage](#usage)
6. [Input Parameters](#input-parameters)
7. [Build Environments](#build-environments)
8. [Date-Based Package Versions](#date-based-package-versions)
9. [GitHub Environments and Secrets](#github-environments-and-secrets)
10. [Build Process](#build-process)
11. [Package Validation](#package-validation)
12. [Customization](#customization)
13. [Contributing](#contributing)

## Overview

The package pipeline performs the following operations:

- prepares the selected Manjaro and BigLinux repositories;
- fully updates the rolling-release build environment;
- obtains the PKGBUILD from a BigLinux, community, or AUR Git repository;
- builds packages with `makepkg` as an unprivileged user;
- runs Namcap checks;
- transfers unsigned packages to a separate publication job;
- validates and signs packages with GPG;
- uploads packages to the selected BigLinux repository;
- updates the repository database;
- optionally creates a GitHub release;
- sends the final result to Telegram.

The build and publication stages run in separate GitHub Actions jobs. Publication credentials are therefore not available to the PKGBUILD or to code executed during compilation.

## Package Pipeline

```text
Build job
  configure repositories
  pacman -Syyu
  clone package source
  makepkg as builduser
  Namcap checks
  upload unsigned artifact
            ↓
Publish job on a fresh runner
  download and validate artifact
  sign packages with GPG
  upload through SSH
  update repository database
  optionally create a GitHub release
            ↓
Notification job
  report the final result to Telegram
```

The same pipeline is used for BigLinux and AUR packages. This keeps maintenance and behavior consistent across all package types.

## Workflows

### Build Package

**File:** `.github/workflows/build-package.yml`

Builds packages from Git repositories containing a PKGBUILD.

It can be started manually with `workflow_dispatch` or remotely with `repository_dispatch`, except for event types beginning with `aur-`.

Main features:

- supports the BigLinux `stable` and `testing` destinations (databases `biglinux-stable` and `biglinux-testing`);
- supports selecting the Manjaro branch used during the rolling update;
- supports a specific source branch;
- supports repositories containing more than one PKGBUILD;
- optionally publishes a GitHub release;
- uploads and updates the BigLinux package repository.

### AUR Package Build

**File:** `.github/workflows/aur-package-build.yml`

Builds packages from the Arch User Repository.

It can be started manually or through a `repository_dispatch` event whose type begins with `aur-`.

Main features:

- validates that the requested package name matches the AUR repository name;
- builds against the current rolling-release repositories;
- installs declared AUR dependencies when required;
- publishes the resulting package to the repository set in `REPO_AUR_BRANCH` (`extra` by default);
- can build the exact AUR commit reviewed by Repo Management (`aur_commit`) and rebuild the same version with a new `pkgrel` (`pkgrel`, e.g. `4.1`);
- uses the same isolated build and publication model as BigLinux packages.

### Reusable Package Pipeline

**File:** `.github/workflows/_secure-package-pipeline.yml`

Contains the shared implementation used by both entry workflows.

It defines three jobs:

- `build`: updates the container and builds unsigned packages without publication secrets;
- `publish`: runs on a fresh runner, validates, signs, and publishes the packages;
- `notify`: sends the final status to Telegram.

### Validation

**File:** `.github/workflows/lint.yml`

Checks workflow and script changes with:

- `actionlint`;
- ShellCheck;
- `bash -n`.

This workflow is separate from package compilation and does not increase normal package build time.

## Custom Action and Scripts

### Custom Action

**File:** `action.yml`

The custom composite action is responsible only for the build stage. It accepts package source and branch settings, then calls `scripts/build-package.sh`.

It does not receive GPG, SSH, Telegram, or repository publication credentials.

### Scripts

The shell logic is kept in regular script files instead of being embedded in large YAML blocks:

| File | Responsibility |
|---|---|
| `scripts/build-package.sh` | Configure repositories, update the system, clone the source, run `makepkg`, execute Namcap, and prepare the artifact. |
| `scripts/publish-package.sh` | Validate package metadata, sign packages, upload through SSH, update the repository database, and optionally create a GitHub release. |
| `scripts/notify.sh` | Telegram: start (step 1/4) and final result (step 4/4 or failure alert). |
| `scripts/telegram.sh` | Telegram helpers shared by the scripts; messages use the big-comm format. One message per build: step 1/4 sends it and every later step (2/4 and 3/4 from `publish-package.sh`, then 4/4 or the failure) edits it, its id passed from job to job; a message that cannot be edited is sent anew. Tested by `tests/test-telegram.sh`. |

Keeping this logic in scripts makes it easier to read, test with ShellCheck, and reuse without turning the workflow YAML into a large shell program.

## Usage

### Repository setup

Keep the following files and directories together:

```text
.github/workflows/
  _secure-package-pipeline.yml
  aur-package-build.yml
  build-package.yml
  lint.yml
action.yml
scripts/
  build-package.sh
  notify.sh
  publish-package.sh
  telegram.sh
```

The scripts are part of the action and must remain executable.

### Repository variables

Set in *Settings → Secrets and variables → Actions → Variables*:

| Variable | Default | Purpose |
|---|---|---|
| `REPO_DB_PREFIX` | `biglinux` | Database prefix: `<prefix>-<branch>.db` |
| `REPO_AUR_BRANCH` | `extra` | Repository that receives AUR builds (`extra`, `testing` or `stable`) |
| `REPO_INCLUDE_SIGS` | `false` | Embed signatures in the database (`repo-add --include-sigs`) |
| `REPO_POST_PUBLISH` | empty | Absolute path of a program on the repository server, run with the repository directory while the publish lock is held, after the database is rebuilt. BigLinux uses it to upload the changed files to the CDN77 bucket and purge the cached database. |

The repository server keeps `<PKGBUILD_DIR>/<branch>/x86_64`. Publication
uploads to a staging directory, then — under `flock` on `.publish.lock` —
moves the files in, runs `repo-add --remove --prevent-downgrade`, deletes
orphaned `.sig`/`.sha256` files and runs `REPO_POST_PUBLISH`.

### Manual build

1. Open the repository on GitHub.
2. Select **Actions**.
3. Select **Build Package** or **AUR Package Build**.
4. Select **Run workflow**.
5. Fill in the package source and destination fields.

### Repository dispatch

BigLinux packages can be triggered with a payload similar to:

```json
{
  "event_type": "build-package",
  "client_payload": {
    "package_name": "example-package",
    "url": "https://github.com/biglinux/example-package.git",
    "branch_type": "testing",
    "manjaro_branch": "stable"
  }
}
```

AUR packages require an event type beginning with `aur-`:

```json
{
  "event_type": "aur-example-package",
  "client_payload": {
    "package_name": "example-package",
    "aur_url": "https://aur.archlinux.org/example-package.git"
  }
}
```

## Input Parameters

### Build Package workflow

| Input | Required | Description |
|---|---:|---|
| `package_name` | Yes | Package or pkgbase name. |
| `source_url` | Yes | HTTPS Git repository containing the PKGBUILD. |
| `branch_type` | Yes | Destination: `testing`, `stable` or `extra` (AUR and third-party packages). |
| `source_branch` | No | Git branch to clone from the source repository. |
| `new_branch` | No | Branch applied to existing BigLinux Git sources in testing builds. |
| `pkgbuild_path` | No | Directory containing the PKGBUILD when the repository has more than one. |
| `manjaro_branch` | Yes | Manjaro repository branch: `stable`, `testing`, or `unstable`. |
| `pacman_mirror` | No | Complete Manjaro mirror URL overriding the automatic mirror. |
| `release_repository` | No | GitHub `owner/repository` used for releases. |
| `publish_github` | Yes | Create or update a GitHub release. |
| `push_to_repo` | Yes | Upload packages to the BigLinux package server. |
| `update_db` | Yes | Update the destination repository database. |

GitHub releases are not created for `testing` or AUR builds.

### AUR Package Build workflow

| Input | Required | Description |
|---|---:|---|
| `package_name` | Yes | AUR package name. |
| `aur_url` | Yes | AUR Git repository URL. |
| `pacman_mirror` | No | Complete Manjaro mirror URL overriding the automatic mirror. |
| `push_to_repo` | Yes | Upload packages to the BigLinux package server. |
| `update_db` | Yes | Update the database of the AUR destination repository. |
| `aur_commit` | No | Build exactly this AUR commit (40-character hash). |
| `pkgrel` | No | Rebuild the same AUR version with this `pkgrel` (e.g. `4.1`). |

### Composite action

The `action.yml` file accepts:

| Input | Description |
|---|---|
| `build_env` | Build environment: `stable`, `testing`, `extra`, or `aur`. |
| `branch_type` | Destination branch. |
| `package_name` | Requested package or pkgbase. |
| `url` | Git repository containing the PKGBUILD. |
| `git_branch` | Optional source branch. |
| `new_branch` | Optional BigLinux testing branch. |
| `manjaro_branch` | Manjaro branch used by Pacman. |
| `pacman_mirror` | Optional complete mirror URL. |
| `pkgbuild_path` | Optional PKGBUILD directory relative to the source repository. |

## Build Environments

The selected repositories are configured before the full update. The build then runs:

```bash
pacman -Syyu --needed --noconfirm
```

Default repository priority:

| Destination | Repository priority |
|---|---|
| `stable` | `community-stable`, `biglinux-stable` |
| `testing` | `community-testing`, `community-stable`, `biglinux-testing`, `biglinux-stable` |
| `extra` / `aur` | `community-extra`, `community-testing`, `community-stable`, `biglinux-testing`, `biglinux-stable` |

This ensures that packages are compiled with the current libraries used by the selected rolling-release environment.

The optional repository variable `BIGLINUX_BUILDER_IMAGE` changes the container image used by the build job. Its default value is:

```text
talesam/community-build:latest
```

## Date-Based Package Versions

Each build exports the following variables to `makepkg`:

```text
BIGLINUX_BUILD_VERSION=YYYYMMDD.HHMM
SOURCE_DATE_EPOCH=<UTC build start timestamp>
BIGLINUX_GIT_BRANCH=<selected source branch>
```

A PKGBUILD can use the standard BigLinux date-based version with:

```bash
pkgver() {
    printf '%s\n' "$BIGLINUX_BUILD_VERSION"
}
```

For VCS packages that should also identify the source commit:

```bash
pkgver() {
    cd "$srcdir/$pkgname"
    printf '%s.r%s.g%s\n' \
        "$BIGLINUX_BUILD_VERSION" \
        "$(git rev-list --count HEAD)" \
        "$(git rev-parse --short=12 HEAD)"
}
```

The timestamp is consistent throughout one build. The pipeline does not retain historical repository snapshots and does not claim byte-for-byte reproducible builds.

## GitHub Environments and Secrets

### `package-production`

Create a GitHub environment named `package-production` with the publication credentials:

| Secret | Purpose |
|---|---|
| `GPG_PRIVATE_KEY` | ASCII-armored private key used to sign packages. |
| `PASSPHRASE` | Passphrase for the GPG key. |
| `PKGBUILD_KEY` | SSH private key used to access the package server. |
| `PKGBUILD_KNOWN_HOSTS` | Trusted SSH host key entries. |
| `PKGBUILD_HOST` | Package server hostname. |
| `PKGBUILD_USER` | Package server SSH user. |
| `PKGBUILD_PORT` | Package server SSH port. |
| `PKGBUILD_DIR` | Absolute package repository path on the server. |
| `REPOSITORY_TOKEN` | Optional token for publishing releases in another repository. |

The publication environment should be restricted to the protected default branch. Required reviewers can be enabled when manual approval is desired before signing and publishing packages.

### `package-notifications`

Create a GitHub environment named `package-notifications` with:

| Secret | Purpose |
|---|---|
| `TOKEN_BOT` | Telegram bot token. |
| `CHAT_ID` | Telegram chat ID. |

Notification credentials are kept separate from package signing and repository credentials.

### SSH host verification

Generate and verify the known-hosts entry from a trusted machine:

```bash
ssh-keyscan -p PORT -t ed25519 HOST > known_hosts
ssh-keygen -lf known_hosts
```

Store the complete verified contents in `PKGBUILD_KNOWN_HOSTS`.

## Build Process

### 1. Build environment preparation

- validates workflow inputs;
- configures the selected Manjaro and BigLinux repositories;
- fully updates the rolling-release environment;
- installs required packaging tools;
- creates an unprivileged `builduser`.

### 2. Source preparation

- validates the Git or AUR URL;
- clones the requested branch;
- locates the PKGBUILD;
- rejects symbolic-link PKGBUILDs and paths outside the source repository;
- generates package metadata.

### 3. Package compilation

- installs declared dependencies;
- runs `makepkg --cleanbuild --clean --syncdeps --noconfirm --nosign`;
- verifies the package files declared by `makepkg --packagelist`;
- executes Namcap checks;
- stores the unsigned packages and build metadata as a GitHub artifact.

### 4. Signing and publication

A new runner:

- downloads and verifies the artifact;
- validates package names, metadata, architecture, and archive paths;
- imports the GPG key into a temporary keyring;
- signs each package and verifies the signatures;
- generates SHA-256 files;
- uploads files to a temporary directory on the package server;
- updates the repository under a branch-specific lock;
- optionally creates or updates a GitHub release.

### 5. Notification

The final job reports build or publication success and failure through Telegram and records execution times in the GitHub Actions summary.

## Package Validation

The pipeline verifies, among other checks:

- the requested package name and source URL;
- the PKGBUILD location;
- package output names declared by `makepkg`;
- presence of `.PKGINFO`, `.BUILDINFO`, and `.MTREE`;
- consistency between package filename and package metadata;
- consistent versions among split packages;
- safe archive paths without absolute paths or `..` traversal;
- SHA-256 digest during artifact transfer;
- GPG signatures after creation.

Namcap findings are currently reported as warnings so existing packages can be improved gradually without blocking every build.

For static source archives, PKGBUILDs should use real SHA-256 checksums. Git sources may use `SKIP`, but should be pinned to a commit or a controlled tag whenever practical.

## Customization

The pipeline can be customized by:

- changing repository priority in `scripts/build-package.sh`;
- setting `BIGLINUX_BUILDER_IMAGE` in GitHub repository variables;
- changing build or publication inputs in the entry workflows;
- extending validation in `scripts/publish-package.sh`;
- adjusting Telegram messages in `scripts/notify.sh` and `scripts/publish-package.sh`.

Avoid placing arbitrary commands, interactive tmate sessions, or source-changing automation in the production pipeline. Those operations should use separate workflows without package publication credentials.

## Contributing

Contributions are welcome. Before submitting changes:

```bash
bash -n scripts/*.sh
shellcheck scripts/*.sh
actionlint
```

Changes to workflows, `action.yml`, and scripts should be reviewed carefully because they affect package creation, signing, and publication.
