#!/usr/bin/env bash
# Cut a data release: gate with the pinned tools, tag by date.
#
# Usage: ./.scripts/release.sh [vYYYY.MM.DD]
#
# Releases of a data set are dated, not versioned: a tag answers "how old is
# my copy?" at a glance, and there is no API surface to be semantic about.
# With no argument the tag is today's date in UTC; a second release on the
# same day gets a .1, .2, ... suffix. Pass a tag to choose one yourself.
#
# Before tagging, this downloads the tools the workflows pin, checks their
# digests, lints the set and builds the artifacts once, so a tag never
# triggers a release that was going to fail. Nothing is pushed: pushing the
# tag is your call, and the pushed tag is what makes the release workflow
# build and attach the artifacts.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [ $# -gt 1 ]; then
    echo "usage: $0 [vYYYY.MM.DD]" >&2
    exit 2
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "release.sh: working tree not clean, commit or stash first" >&2
    exit 1
fi

# The pins live in the workflow, and nowhere else, so read them from there.
pin() { sed -n "s/^  $2: *//p" ".github/workflows/$1" | sed 's/^"\(.*\)"$/\1/'; }
tools_repo=$(pin release.yml TOOLS_REPO)
tools_tag=$(pin release.yml TOOLS_TAG)
lint_sha=$(pin release.yml LINT_SHA256)
build_sha=$(pin release.yml BUILD_SHA256)
if [ -z "$tools_tag" ] || [ -z "$lint_sha" ] || [ -z "$build_sha" ]; then
    echo "release.sh: no tools release is pinned in .github/workflows/release.yml" >&2
    echo "            run ./.scripts/update-tools.sh first" >&2
    exit 1
fi
# stores.toml is only validated by gamedb-tools 0.2.0 and newer; an older pin
# would build an invalid store list without a word.
case "$tools_tag" in
gamedb-tools-v0.[01].*)
    if [ -f stores.toml ]; then
        echo "release.sh: stores.toml needs gamedb-tools-v0.2.0 or newer, $tools_tag is pinned" >&2
        echo "            run ./.scripts/update-tools.sh first" >&2
        exit 1
    fi
    ;;
esac

if [ $# -eq 1 ]; then
    tag=$1
    case $tag in
    v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]*) ;;
    *) echo "release.sh: tag should look like v2026.08.23 (optionally .N)" >&2; exit 2 ;;
    esac
else
    tag="v$(date -u +%Y.%m.%d)"
    n=0
    while git rev-parse -q --verify "refs/tags/$tag" >/dev/null; do
        n=$((n + 1))
        tag="v$(date -u +%Y.%m.%d).$n"
    done
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "release.sh: tag $tag already exists" >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "release.sh: fetching $tools_repo $tools_tag"
gh release download "$tools_tag" --repo "$tools_repo" \
    --pattern gamedb-lint --pattern gamedb-build --dir "$tmp"
printf '%s  %s\n%s  %s\n' \
    "$lint_sha" "$tmp/gamedb-lint" \
    "$build_sha" "$tmp/gamedb-build" | sha256sum -c -
chmod +x "$tmp/gamedb-lint" "$tmp/gamedb-build"

# The same gate the release workflow runs.
"$tmp/gamedb-lint" .
rm -rf "$tmp/build"
"$tmp/gamedb-build" --data . --out "$tmp/build/" --commit "$(git rev-parse HEAD)"

echo "release.sh: tagging $tag at $(git rev-parse --short HEAD)"
git tag -a "$tag" -m "gamebus-gamedb $tag, built with $tools_tag"

cat <<MSG

Tagged $tag. Nothing was pushed. When you are ready:

    git push github $tag

The release workflow then builds the artifacts with $tools_tag and attaches
them to the release it creates from the tag.
MSG
