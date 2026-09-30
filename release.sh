#!/bin/bash
# Publishes a new version: ./release.sh 1.2.0 "What changed"
# Bumps VERSION, commits, tags and pushes. GitHub Actions then builds the app and creates the release,
# and every installed copy offers the update within a few hours (or via StockGrid › Check for Updates…).
set -euo pipefail
cd "$(dirname "$0")"
NEW="${1:?Usage: ./release.sh <version> [notes]}"
NOTES="${2:-StockGrid $NEW}"
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first."; exit 1; }
echo "$NEW" > VERSION
git add VERSION
git commit -m "Release $NEW"
git tag -a "v$NEW" -m "$NOTES"
git push origin HEAD "v$NEW"
echo "Pushed v$NEW. Watch the build: gh run watch --repo $(gh repo view --json nameWithOwner -q .nameWithOwner)"
