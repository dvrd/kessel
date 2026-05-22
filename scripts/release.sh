#!/bin/bash
# kessel release automation
#
# Usage:
#   scripts/release.sh patch    # 0.1.0 → 0.1.1
#   scripts/release.sh minor    # 0.1.0 → 0.2.0
#   scripts/release.sh major    # 0.1.0 → 1.0.0
#   scripts/release.sh          # auto-detect from commits (conventional commits)
#
# What it does:
#   1. Runs the full test suite (task test:release)
#   2. Determines the version bump from commit messages (or CLI arg)
#   3. Updates package.json version
#   4. Generates changelog entry from conventional commits
#   5. Builds libkessel for the current platform
#   6. Runs npm test
#   7. Commits version bump + changelog
#   8. Tags the release
#   9. Packs and publishes to npm
#
# Prerequisites:
#   - Clean working tree (no uncommitted changes)
#   - npm login (authenticated)
#   - task, odin, node installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$ROOT/npm"
PKG_JSON="$PKG_DIR/package.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}→${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Pre-checks
# ---------------------------------------------------------------------------

cd "$ROOT"

# Clean working tree
if [[ -n "$(git status --porcelain)" ]]; then
  error "Working tree is dirty. Commit or stash changes first."
fi

# Current version
CURRENT_VERSION=$(node -p "require('$PKG_JSON').version")
info "Current version: $CURRENT_VERSION"

# ---------------------------------------------------------------------------
# 2. Determine bump type
# ---------------------------------------------------------------------------

BUMP="${1:-auto}"

if [[ "$BUMP" == "auto" ]]; then
  # Detect from conventional commits since last tag
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  if [[ -z "$LAST_TAG" ]]; then
    COMMITS=$(git log --oneline --format="%s")
  else
    COMMITS=$(git log --oneline --format="%s" "$LAST_TAG..HEAD")
  fi

  if echo "$COMMITS" | grep -qE "^(feat|refactor)!:|BREAKING CHANGE"; then
    BUMP="major"
  elif echo "$COMMITS" | grep -qE "^feat"; then
    BUMP="minor"
  else
    BUMP="patch"
  fi
  info "Auto-detected bump: $BUMP (from commit messages)"
fi

# Calculate new version
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
  *) error "Unknown bump type: $BUMP (use major/minor/patch)" ;;
esac
NEW_VERSION="$MAJOR.$MINOR.$PATCH"
info "New version: $NEW_VERSION"

# ---------------------------------------------------------------------------
# 3. Run tests
# ---------------------------------------------------------------------------

info "Running test suite..."
task test:release || error "Tests failed. Fix before releasing."

# ---------------------------------------------------------------------------
# 4. Build shared library
# ---------------------------------------------------------------------------

info "Building libkessel..."
task build:lib

# ---------------------------------------------------------------------------
# 5. Run npm test
# ---------------------------------------------------------------------------

info "Running npm package tests..."
cd "$PKG_DIR"
node test.js || error "npm test failed."
cd "$ROOT"

# ---------------------------------------------------------------------------
# 6. Generate changelog entry
# ---------------------------------------------------------------------------

info "Generating changelog..."

TODAY=$(date +%Y-%m-%d)
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [[ -z "$LAST_TAG" ]]; then
  RANGE="HEAD"
else
  RANGE="$LAST_TAG..HEAD"
fi

# Collect conventional commits grouped by type
FEATS=$(git log --oneline --format="%s" $RANGE | grep -E "^feat" | sed 's/^feat[:(]//' | sed 's/).*/:/' || true)
FIXES=$(git log --oneline --format="%s" $RANGE | grep -E "^fix" | sed 's/^fix[:(]//' | sed 's/).*/:/' || true)
PERFS=$(git log --oneline --format="%s" $RANGE | grep -E "^perf" | sed 's/^perf[:(]//' | sed 's/).*/:/' || true)
REFACTORS=$(git log --oneline --format="%s" $RANGE | grep -E "^refactor" | sed 's/^refactor[:(]//' | sed 's/).*/:/' || true)

CHANGELOG_ENTRY="## [$NEW_VERSION] - $TODAY\n"
if [[ -n "$FEATS" ]]; then
  CHANGELOG_ENTRY+="\n### Added\n"
  while IFS= read -r line; do CHANGELOG_ENTRY+="- $line\n"; done <<< "$FEATS"
fi
if [[ -n "$FIXES" ]]; then
  CHANGELOG_ENTRY+="\n### Fixed\n"
  while IFS= read -r line; do CHANGELOG_ENTRY+="- $line\n"; done <<< "$FIXES"
fi
if [[ -n "$PERFS" ]]; then
  CHANGELOG_ENTRY+="\n### Performance\n"
  while IFS= read -r line; do CHANGELOG_ENTRY+="- $line\n"; done <<< "$PERFS"
fi
if [[ -n "$REFACTORS" ]]; then
  CHANGELOG_ENTRY+="\n### Changed\n"
  while IFS= read -r line; do CHANGELOG_ENTRY+="- $line\n"; done <<< "$REFACTORS"
fi

# Prepend to CHANGELOG.md (after the header lines)
CHANGELOG="$ROOT/CHANGELOG.md"
if [[ -f "$CHANGELOG" ]]; then
  # Insert after the "# Changelog" header and format description
  HEADER=$(head -5 "$CHANGELOG")
  BODY=$(tail -n +6 "$CHANGELOG")
  echo -e "$HEADER\n\n$CHANGELOG_ENTRY\n$BODY" > "$CHANGELOG"
else
  echo -e "# Changelog\n\n$CHANGELOG_ENTRY" > "$CHANGELOG"
fi

# ---------------------------------------------------------------------------
# 7. Update version in package.json
# ---------------------------------------------------------------------------

info "Updating package.json version to $NEW_VERSION..."
cd "$PKG_DIR"
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.version = '$NEW_VERSION';
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
cd "$ROOT"

# ---------------------------------------------------------------------------
# 8. Commit + tag
# ---------------------------------------------------------------------------

info "Committing release..."
git add "$PKG_JSON" "$CHANGELOG"
git commit -m "release: v$NEW_VERSION

See CHANGELOG.md for details."
git tag -a "v$NEW_VERSION" -m "v$NEW_VERSION"

# ---------------------------------------------------------------------------
# 9. Publish
# ---------------------------------------------------------------------------

info "Publishing to npm..."
cd "$PKG_DIR"
npm publish

cd "$ROOT"
info "Pushing tags..."
git push && git push --tags

echo ""
echo -e "${GREEN}✓ Released kessel v$NEW_VERSION${NC}"
echo "  npm: https://www.npmjs.com/package/kessel"
echo "  tag: v$NEW_VERSION"
