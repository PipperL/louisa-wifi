#!/bin/bash
# Publish a release of this fork as the owner. Run with the owner's own credentials
# (their machine, or the sandbox whose proxy injects the owner's token), never from
# a workflow: the app only accepts releases whose author and zip uploader are the owner.
#
#   scripts/release.sh tag v0.2.0       push the tag; build.yml builds it
#   scripts/release.sh draft v0.2.0 NOTES.md
#                                       wait for that build, check it, create a draft release with the zip;
#                                       NOTES.md (required) is a short summary of the main changes
#   scripts/release.sh publish v0.2.0   publish the draft (immutable from then on, if enabled)
#
# Each step is separate so the owner can confirm before anything becomes public.
set -euo pipefail

REPO=PipperL/louisa-wifi
OWNER=PipperL
step=${1:-}; tag=${2:-}; notes_file=${3:-}
[[ "$tag" =~ ^v[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "usage: $0 tag|draft|publish vX.Y.Z" >&2; exit 2; }
[ "$(gh api user --jq .login)" = "$OWNER" ] || { echo "not authenticated as $OWNER" >&2; exit 1; }

case "$step" in
tag)
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "HEAD is not origin/main" >&2; exit 1; }
  git diff --quiet HEAD || { echo "working tree not clean" >&2; exit 1; }
  if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then echo "$tag already exists" >&2; exit 1; fi
  git tag "$tag" HEAD
  git push origin "refs/tags/$tag"     # only this tag; never --tags (upstream's tags are local too)
  echo "pushed $tag at $(git rev-parse --short HEAD); build.yml is building it"
  ;;
draft)
  sha=$(git ls-remote origin "refs/tags/$tag" | cut -f1)
  [ -n "$sha" ] || { echo "$tag not on origin" >&2; exit 1; }
  echo "waiting for the build of $tag ($sha)…"
  for _ in $(seq 1 90); do
    run=$(gh run list -R "$REPO" --workflow build.yml --branch "$tag" --json databaseId,headSha,status,conclusion \
          --jq "map(select(.headSha == \"$sha\")) | .[0]")
    [ -n "$run" ] && [ "$(jq -r .status <<<"$run")" = completed ] && break
    sleep 20
  done
  [ "$(jq -r .conclusion <<<"$run")" = success ] || { echo "build not successful: $run" >&2; exit 1; }
  id=$(jq -r .databaseId <<<"$run")
  dir=$(mktemp -d)
  gh run download "$id" -R "$REPO" -D "$dir"
  zip=$(find "$dir" -name LouisaWiFi.zip | head -1)
  actual=$(shasum -a 256 "$zip" 2>/dev/null | cut -d' ' -f1 || sha256sum "$zip" | cut -d' ' -f1)
  logged=$(gh run view "$id" -R "$REPO" --log | grep -oE '[0-9a-f]{64}  build/LouisaWiFi.zip' | head -1 | cut -d' ' -f1)
  [ -n "$logged" ] && [ "$actual" = "$logged" ] || { echo "SHA-256 mismatch: artifact $actual, build log $logged" >&2; exit 1; }
  [ -s "$notes_file" ] || { echo "draft needs a non-empty release notes file: $0 draft $tag NOTES.md" >&2; exit 2; }
  notes="$(cat "$notes_file")

Commit: $sha
Build: https://github.com/$REPO/actions/runs/$id
SHA-256 (LouisaWiFi.zip): $actual"
  gh release create "$tag" "$zip" -R "$REPO" --draft --verify-tag --title "$tag (${sha:0:7})" --notes "$notes"
  echo "draft created for $tag; SHA-256 $actual"
  ;;
publish)
  rel=$(gh api "repos/$REPO/releases" --jq "map(select(.tag_name == \"$tag\")) | .[0]")
  [ -n "$rel" ] && [ "$rel" != null ] || { echo "no release for $tag" >&2; exit 1; }
  jq -r '"draft=\(.draft) author=\(.author.login) uploaders=\([.assets[].uploader.login] | unique | join(","))"' <<<"$rel"
  [ "$(jq -r '.author.login' <<<"$rel")" = "$OWNER" ] || { echo "release author is not $OWNER" >&2; exit 1; }
  [ "$(jq -r '[.assets[].uploader.login] | unique | join(",")' <<<"$rel")" = "$OWNER" ] || { echo "asset uploader is not $OWNER" >&2; exit 1; }
  gh api -X PATCH "repos/$REPO/releases/$(jq -r .id <<<"$rel")" -F draft=false \
    --jq '"published \(.html_url) immutable=\(.immutable // "unknown")"'
  ;;
*)
  echo "usage: $0 tag|draft|publish vX.Y.Z" >&2; exit 2 ;;
esac
