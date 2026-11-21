#!/bin/bash
set -euo pipefail

DEFAULT_REPO="ThisRadLife/shakeboard"
PAGES_URL="https://thisradlife.github.io/shakeboard/"

usage() {
  cat <<'EOF'
Usage: scripts/publish-site.sh [--dry-run] [--yes]

Publishes the committed site/ tree from the current HEAD to gh-pages while
preserving the shared appcast.xml update feed and the root CNAME.
Set SHAKEBOARD_REPO=owner/repo to use another repository.

Options:
  --dry-run  Show the proposed gh-pages changes without committing or pushing.
  --yes      Commit and push without the y/N prompt.
EOF
}

DRY_RUN=0
ASSUME_YES=0
while (( $# > 0 )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) echo "Unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for TOOL in git rsync shasum tar xmllint; do
  command -v "$TOOL" >/dev/null || { echo "Required tool not found: $TOOL" >&2; exit 1; }
done

REPO="${SHAKEBOARD_REPO:-$DEFAULT_REPO}"
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "SHAKEBOARD_REPO must have the form owner/repo" >&2
  exit 2
fi

# Test-only escape hatch for local bare repositories. Normal publishes always derive
# the destination from SHAKEBOARD_REPO and never use the checkout's origin remote.
PUBLISH_REPO_URL="${SHAKEBOARD_PUBLISH_URL:-https://github.com/${REPO}.git}"
ROOT_DIR="$(git rev-parse --show-toplevel)"
SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_SHORT_SHA="$(git -C "$ROOT_DIR" rev-parse --short "$SOURCE_SHA")"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shakeboard-site.XXXXXX")"
EXPORT_DIR="$TEMP_DIR/export"
WORKTREE_DIR="$TEMP_DIR/gh-pages"
WORKTREE_BRANCH="publish-site-${SOURCE_SHORT_SHA}-$$"
MASTER_REF="refs/shakeboard-site/master-${SOURCE_SHORT_SHA}-$$"
PAGES_REF="refs/shakeboard-site/gh-pages-${SOURCE_SHORT_SHA}-$$"
WORKTREE_ADDED=0

cleanup() {
  if (( WORKTREE_ADDED )); then
    git -C "$ROOT_DIR" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
    git -C "$ROOT_DIR" branch -D "$WORKTREE_BRANCH" >/dev/null 2>&1 || true
  fi
  git -C "$ROOT_DIR" update-ref -d "$MASTER_REF" >/dev/null 2>&1 || true
  git -C "$ROOT_DIR" update-ref -d "$PAGES_REF" >/dev/null 2>&1 || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain -- site)" ]]; then
  echo "site/ has uncommitted changes; commit them before publishing" >&2
  git -C "$ROOT_DIR" status --short -- site >&2
  exit 1
fi
if [[ ! -d "$ROOT_DIR/site" ]]; then
  echo "site/ does not exist" >&2
  exit 1
fi
APPCAST_IN_COMMIT="$(git -C "$ROOT_DIR" ls-tree -r --name-only "$SOURCE_SHA" -- site | awk -F/ '
  {
    for (i = 1; i <= NF; i++) {
      if ($i == "appcast.xml") {
        print
        exit
      }
    }
  }
')"
APPCAST_IN_SITE="$(find "$ROOT_DIR/site" -name appcast.xml -print -quit)"
if [[ -n "$APPCAST_IN_COMMIT" ]]; then
  echo "Refusing to publish: committed site/ must never contain appcast.xml ($APPCAST_IN_COMMIT)" >&2
  exit 1
fi
if [[ -n "$APPCAST_IN_SITE" ]]; then
  echo "Refusing to publish: site/ must never contain appcast.xml ($APPCAST_IN_SITE)" >&2
  exit 1
fi

# Fetch and push the configured release repository directly. The checkout's origin may
# still use an old repository name and must never decide where the public site lands.
git -C "$ROOT_DIR" fetch "$PUBLISH_REPO_URL" "refs/heads/master:$MASTER_REF" >/dev/null
if ! git -C "$ROOT_DIR" merge-base --is-ancestor "$SOURCE_SHA" "$MASTER_REF"; then
  if (( ASSUME_YES )); then
    echo "HEAD $SOURCE_SHORT_SHA is not contained in $REPO master; refusing because --yes was supplied" >&2
    exit 1
  fi
  echo "Warning: HEAD $SOURCE_SHORT_SHA is not contained in $REPO master" >&2
fi

set +e
git ls-remote --exit-code "$PUBLISH_REPO_URL" refs/heads/gh-pages >/dev/null 2>&1
LS_REMOTE_STATUS=$?
set -e
case "$LS_REMOTE_STATUS" in
  0)
    git -C "$ROOT_DIR" fetch "$PUBLISH_REPO_URL" "refs/heads/gh-pages:$PAGES_REF" >/dev/null
    git -C "$ROOT_DIR" worktree add -b "$WORKTREE_BRANCH" "$WORKTREE_DIR" "$PAGES_REF" >/dev/null
    WORKTREE_ADDED=1
    ;;
  2)
    git -C "$ROOT_DIR" worktree add --detach "$WORKTREE_DIR" "$SOURCE_SHA" >/dev/null
    WORKTREE_ADDED=1
    git -C "$WORKTREE_DIR" checkout --orphan "$WORKTREE_BRANCH" >/dev/null
    git -C "$WORKTREE_DIR" rm -rf . >/dev/null
    ;;
  *)
    echo "Could not inspect gh-pages at $PUBLISH_REPO_URL" >&2
    exit 1
    ;;
esac

APPCAST_PATH="$WORKTREE_DIR/appcast.xml"
APPCAST_EXISTED=0
APPCAST_SHA_BEFORE=""
if [[ -e "$APPCAST_PATH" || -L "$APPCAST_PATH" ]]; then
  if [[ ! -f "$APPCAST_PATH" || -L "$APPCAST_PATH" ]]; then
    echo "Existing gh-pages appcast.xml is not a regular file" >&2
    exit 1
  fi
  APPCAST_EXISTED=1
  APPCAST_SHA_BEFORE="$(shasum -a 256 "$APPCAST_PATH" | awk '{ print $1 }')"
fi

mkdir "$EXPORT_DIR"
git -C "$ROOT_DIR" archive "$SOURCE_SHA" site | tar -x -C "$EXPORT_DIR"
rsync -a --delete \
  --filter='P /appcast.xml' \
  --filter='P /CNAME' \
  --exclude='/.git' \
  "$EXPORT_DIR/site/" "$WORKTREE_DIR/"
touch "$WORKTREE_DIR/.nojekyll"

if (( APPCAST_EXISTED )); then
  if [[ ! -f "$APPCAST_PATH" ]]; then
    echo "Safety check failed: appcast.xml disappeared during site publication" >&2
    exit 1
  fi
  APPCAST_SHA_AFTER="$(shasum -a 256 "$APPCAST_PATH" | awk '{ print $1 }')"
  if [[ "$APPCAST_SHA_AFTER" != "$APPCAST_SHA_BEFORE" ]]; then
    echo "Safety check failed: appcast.xml changed during site publication" >&2
    exit 1
  fi
  xmllint --noout "$APPCAST_PATH"
elif [[ -e "$APPCAST_PATH" || -L "$APPCAST_PATH" ]]; then
  echo "Safety check failed: site publication created appcast.xml" >&2
  exit 1
fi

echo "Source: $SOURCE_SHA"
echo "Publish destination: $PUBLISH_REPO_URL (gh-pages)"
CHANGES="$(git -C "$WORKTREE_DIR" status --porcelain)"
git -C "$WORKTREE_DIR" status --short
git -C "$WORKTREE_DIR" add -N .
git -C "$WORKTREE_DIR" diff --stat

if [[ -z "$CHANGES" ]]; then
  echo "No site changes to publish"
  echo "Pages URL: $PAGES_URL"
  exit 0
fi

if (( DRY_RUN )); then
  echo "Dry run complete; nothing was committed or pushed"
  echo "Pages URL: $PAGES_URL"
  exit 0
fi

if (( ! ASSUME_YES )); then
  printf 'Commit and push these site changes to gh-pages? [y/N] '
  if ! read -r ANSWER || [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
    echo "Cancelled; nothing was committed or pushed"
    exit 0
  fi
fi

git -C "$WORKTREE_DIR" add -A
git -C "$WORKTREE_DIR" commit -s -m "Publish site from $SOURCE_SHORT_SHA"
if ! git -C "$WORKTREE_DIR" push "$PUBLISH_REPO_URL" HEAD:gh-pages; then
  echo "Push rejected or failed. gh-pages may have moved (for example, an appcast publish raced); rerun scripts/publish-site.sh." >&2
  exit 1
fi
echo "Published site from $SOURCE_SHORT_SHA"
echo "Pages URL: $PAGES_URL"
