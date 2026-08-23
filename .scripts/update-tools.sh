#!/usr/bin/env bash
# Move the workflows' tool pin to the latest gamedb-tools release.
#
# Usage: ./.scripts/update-tools.sh [gamedb-tools-vX.Y.Z]
#
# The lint and the builder are not kept here. The workflows download one
# pinned release of them from gamebus-presenced and check its digest, and
# this is the one place that pin changes. With no argument the newest
# gamedb-tools-v* release is used; pass a tag to pin a specific one.
#
# A new pin is proven before it is written: the release's binaries are
# downloaded, checked against its SHA256SUMS, and run against this data set.
# Only then do the tag and digests go into both workflows, as one commit.
# Nothing is pushed.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [ $# -gt 1 ]; then
    echo "usage: $0 [gamedb-tools-vX.Y.Z]" >&2
    exit 2
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "update-tools.sh: working tree not clean, commit or stash first" >&2
    exit 1
fi

lint_yml=.github/workflows/lint.yml
release_yml=.github/workflows/release.yml
pin() { sed -n "s/^  $2: *//p" "$1" | sed 's/^"\(.*\)"$/\1/'; }
tools_repo=$(pin "$release_yml" TOOLS_REPO)
current=$(pin "$release_yml" TOOLS_TAG)

if [ $# -eq 1 ]; then
    tag=$1
else
    # Newest gamedb-tools-v* release; the daemon's own v* releases are
    # filtered out, since they carry no tools.
    tag=$(gh release list --repo "$tools_repo" --limit 50 \
        --json tagName --jq '[.[].tagName | select(startswith("gamedb-tools-v"))] | first // empty')
    if [ -z "$tag" ]; then
        echo "update-tools.sh: $tools_repo has no gamedb-tools-v* release" >&2
        exit 1
    fi
fi
if [ "$tag" = "$current" ]; then
    echo "update-tools.sh: already pinned to $tag"
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "update-tools.sh: ${current:-nothing} -> $tag"
gh release download "$tag" --repo "$tools_repo" \
    --pattern gamedb-lint --pattern gamedb-build --pattern SHA256SUMS --dir "$tmp"
lint_sha=$(awk '$2=="gamedb-lint"{print $1}' "$tmp/SHA256SUMS")
build_sha=$(awk '$2=="gamedb-build"{print $1}' "$tmp/SHA256SUMS")
if [ -z "$lint_sha" ] || [ -z "$build_sha" ]; then
    echo "update-tools.sh: the release's SHA256SUMS does not name both binaries" >&2
    exit 1
fi
# The digests in SHA256SUMS are what gets pinned, so check the downloaded
# binaries against them, not the other way round.
(cd "$tmp" && sha256sum -c SHA256SUMS)
chmod +x "$tmp/gamedb-lint" "$tmp/gamedb-build"

# A pin is a claim that these tools work on this data. Prove it first.
"$tmp/gamedb-lint" .
"$tmp/gamedb-build" --data . --out "$tmp/build/" --commit "$(git rev-parse HEAD)" >/dev/null
echo "update-tools.sh: $tag lints and builds this data set"

sed -i "s|^  TOOLS_TAG: \".*\"|  TOOLS_TAG: \"$tag\"|; s|^  LINT_SHA256: \".*\"|  LINT_SHA256: \"$lint_sha\"|" "$lint_yml"
sed -i "s|^  TOOLS_TAG: \".*\"|  TOOLS_TAG: \"$tag\"|; s|^  LINT_SHA256: \".*\"|  LINT_SHA256: \"$lint_sha\"|; s|^  BUILD_SHA256: \".*\"|  BUILD_SHA256: \"$build_sha\"|" "$release_yml"

# Every pin in both files must now read the same, or the sed above missed one.
for want in "TOOLS_TAG $tag" "LINT_SHA256 $lint_sha"; do
    set -- $want
    for f in "$lint_yml" "$release_yml"; do
        [ "$(pin "$f" "$1")" = "$2" ] || { echo "update-tools.sh: $1 did not land in $f" >&2; exit 1; }
    done
done
[ "$(pin "$release_yml" BUILD_SHA256)" = "$build_sha" ] || { echo "update-tools.sh: BUILD_SHA256 did not land" >&2; exit 1; }

git add "$lint_yml" "$release_yml"
git commit -q -F - <<MSG
Pin the tools at $tag

gamedb-lint and gamedb-build from $tools_repo $tag, by tag and digest. Both
were run against this data set before the pin was written.

  gamedb-lint   $lint_sha
  gamedb-build  $build_sha
MSG

cat <<MSG

Pinned $tag in both workflows and committed. Nothing was pushed. When you
are ready:

    git push github main
MSG
