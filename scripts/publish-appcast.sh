#!/bin/bash
set -euo pipefail

SPARKLE_VERSION="2.10.1"
SPARKLE_ARCHIVE="Sparkle-${SPARKLE_VERSION}.tar.xz"
SPARKLE_ARCHIVE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
DEFAULT_REPO="ThisRadLife/shakeboard"
EXPECTED_BUNDLE_ID="com.thisradlife.shakeboard"
EXPECTED_TEAM_ID="DQ9FW5YXUQ"

usage() {
  cat <<'EOF'
Usage: scripts/publish-appcast.sh [--dry-run] [--yes] vX.Y.Z

Downloads and verifies a published ShakeBoard release, signs its DMG update
with the Sparkle EdDSA key in the login Keychain, and updates appcast.xml on
gh-pages. Set SHAKEBOARD_REPO=owner/repo to use another repository.

Options:
  --dry-run  Write /tmp/ShakeBoard-appcast-X.Y.Z.xml without committing or pushing.
  --yes      Print the diff, then commit and push without the y/N prompt.
EOF
}

DRY_RUN=0
ASSUME_YES=0
TAG=""
while (( $# > 0 )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$TAG" ]]; then
        echo "Only one release tag may be supplied" >&2
        usage >&2
        exit 2
      fi
      TAG="$1"
      ;;
  esac
  shift
done

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Tag must have the form vX.Y.Z" >&2
  usage >&2
  exit 2
fi

for TOOL in gh git shasum xcrun spctl hdiutil xmllint codesign; do
  command -v "$TOOL" >/dev/null || { echo "Required tool not found: $TOOL" >&2; exit 1; }
done

REPO="${SHAKEBOARD_REPO:-$DEFAULT_REPO}"
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "SHAKEBOARD_REPO must have the form owner/repo" >&2
  exit 2
fi
VERSION="${TAG#v}"
DMG_NAME="ShakeBoard-${VERSION}.dmg"
SHA_NAME="${DMG_NAME}.sha256"
ASSET_URL="https://github.com/${REPO}/releases/download/${TAG}/${DMG_NAME}"
PUBLISH_REPO_URL="https://github.com/${REPO}.git"
ROOT_DIR="$(git rev-parse --show-toplevel)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shakeboard-appcast.XXXXXX")"
WORKTREE_DIR="$TEMP_DIR/gh-pages"
WORKTREE_BRANCH="publish-appcast-${VERSION//./-}-$$"
FETCH_REF="refs/shakeboard-appcast/${WORKTREE_BRANCH}"
MOUNT_DIR="$TEMP_DIR/mount"
WORKTREE_ADDED=0
MOUNTED=0

cleanup() {
  if (( MOUNTED )); then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  if (( WORKTREE_ADDED )); then
    git -C "$ROOT_DIR" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
    git -C "$ROOT_DIR" branch -D "$WORKTREE_BRANCH" >/dev/null 2>&1 || true
  fi
  git -C "$ROOT_DIR" update-ref -d "$FETCH_REF" >/dev/null 2>&1 || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

IS_DRAFT="$(gh release view "$TAG" -R "$REPO" --json isDraft --jq '.isDraft')"
if [[ "$IS_DRAFT" != "false" ]]; then
  echo "Release $TAG is still a draft; publish it before updating the appcast" >&2
  exit 1
fi
IS_PRERELEASE="$(gh release view "$TAG" -R "$REPO" --json isPrerelease --jq '.isPrerelease')"
if [[ "$IS_PRERELEASE" != "false" ]]; then
  echo "Release $TAG is a prerelease; production appcasts accept final releases only" >&2
  exit 1
fi
REPO_VISIBILITY="$(gh repo view "$REPO" --json visibility --jq '.visibility')"
if [[ "$REPO_VISIBILITY" != "PUBLIC" ]]; then
  echo "Repository $REPO must be public so installed apps can download updates" >&2
  exit 1
fi
RELEASE_TITLE="$(gh release view "$TAG" -R "$REPO" --json name --jq '.name')"
PUBLISHED_AT="$(gh release view "$TAG" -R "$REPO" --json publishedAt --jq '.publishedAt')"
[[ -n "$RELEASE_TITLE" ]] || RELEASE_TITLE="ShakeBoard $VERSION"
if [[ -z "$PUBLISHED_AT" ]]; then
  echo "Release $TAG has no publication date" >&2
  exit 1
fi
PUB_DATE="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$PUBLISHED_AT" '+%a, %d %b %Y %H:%M:%S +0000')"

gh release download "$TAG" -R "$REPO" -D "$TEMP_DIR" -p "$DMG_NAME" -p "$SHA_NAME"
EXPECTED_DMG_SHA256="$(awk 'NR == 1 { print $1 }' "$TEMP_DIR/$SHA_NAME")"
if [[ ! "$EXPECTED_DMG_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Release checksum file does not begin with a SHA-256 digest" >&2
  exit 1
fi
ACTUAL_DMG_SHA256="$(shasum -a 256 "$TEMP_DIR/$DMG_NAME" | awk '{ print $1 }')"
EXPECTED_DMG_SHA256="$(printf '%s' "$EXPECTED_DMG_SHA256" | tr '[:upper:]' '[:lower:]')"
if [[ "$ACTUAL_DMG_SHA256" != "$EXPECTED_DMG_SHA256" ]]; then
  echo "DMG SHA-256 does not match $SHA_NAME" >&2
  exit 1
fi
echo "$DMG_NAME: SHA-256 verified"
xcrun stapler validate "$TEMP_DIR/$DMG_NAME"
spctl -a -t open --context context:primary-signature -v "$TEMP_DIR/$DMG_NAME"
DMG_SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$TEMP_DIR/$DMG_NAME" 2>&1)"
if ! grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$DMG_SIGNATURE_DETAILS"; then
  echo "DMG is not signed by expected Team ID $EXPECTED_TEAM_ID" >&2
  exit 1
fi

gh release download "$SPARKLE_VERSION" \
  -R sparkle-project/Sparkle \
  -D "$TEMP_DIR" \
  -p "$SPARKLE_ARCHIVE"
printf '%s  %s\n' "$SPARKLE_ARCHIVE_SHA256" "$TEMP_DIR/$SPARKLE_ARCHIVE" | shasum -a 256 -c -
tar -xJf "$TEMP_DIR/$SPARKLE_ARCHIVE" -C "$TEMP_DIR"
SIGN_UPDATE="$(find "$TEMP_DIR" -type f -path '*/bin/sign_update' -perm -111 -print -quit)"
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "Sparkle sign_update was not found in $SPARKLE_ARCHIVE" >&2
  exit 1
fi

FILE_LENGTH="$(stat -f '%z' "$TEMP_DIR/$DMG_NAME")"

mkdir "$MOUNT_DIR"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$TEMP_DIR/$DMG_NAME" >/dev/null
MOUNTED=1
APP_PATH="$(find "$MOUNT_DIR" -maxdepth 2 -type d -name 'ShakeBoard.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "ShakeBoard.app was not found in the mounted DMG" >&2
  exit 1
fi
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [[ "$SHORT_VERSION" != "$VERSION" ]]; then
  echo "DMG app version $SHORT_VERSION does not match tag version $VERSION" >&2
  exit 1
fi
if [[ ! "$BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "DMG app CFBundleVersion is not a numeric Apple bundle version: $BUILD_VERSION" >&2
  exit 1
fi
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "DMG app bundle ID $BUNDLE_ID does not match $EXPECTED_BUNDLE_ID" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
APP_SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
if ! grep -Fq "Identifier=$EXPECTED_BUNDLE_ID" <<< "$APP_SIGNATURE_DETAILS"; then
  echo "DMG app signature identifier does not match $EXPECTED_BUNDLE_ID" >&2
  exit 1
fi
if ! grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$APP_SIGNATURE_DETAILS"; then
  echo "DMG app is not signed by expected Team ID $EXPECTED_TEAM_ID" >&2
  exit 1
fi
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNTED=0

# Fetch and push the configured release repository directly. The checkout's origin may
# still use an old repository name and must never decide where the public feed lands.
git -C "$ROOT_DIR" fetch "$PUBLISH_REPO_URL" "refs/heads/gh-pages:$FETCH_REF"
git -C "$ROOT_DIR" worktree add -b "$WORKTREE_BRANCH" "$WORKTREE_DIR" "$FETCH_REF" >/dev/null
WORKTREE_ADDED=1

# sign_update retrieves the EdDSA private key from the maintainer's login Keychain.
# The script deliberately has no private-key command-line argument or environment variable.
SIGNATURE_OUTPUT="$("$SIGN_UPDATE" "$TEMP_DIR/$DMG_NAME")"
ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$SIGNATURE_OUTPUT")"
if [[ -z "$ED_SIGNATURE" ]]; then
  echo "Could not parse sparkle:edSignature from sign_update output" >&2
  printf '%s\n' "$SIGNATURE_OUTPUT" >&2
  exit 1
fi

OLD_ITEMS="$TEMP_DIR/old-items.xml"
OLD_ITEM_COUNT=0
if [[ -f "$WORKTREE_DIR/appcast.xml" ]]; then
  xmllint --noout "$WORKTREE_DIR/appcast.xml"
  MATCHING_ITEM_COUNT="$(xmllint --xpath \
    "count(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item']/*[local-name()='enclosure'][@url='$ASSET_URL'])" \
    "$WORKTREE_DIR/appcast.xml")"
  if [[ "$MATCHING_ITEM_COUNT" != "0" ]]; then
    echo "appcast.xml already contains $ASSET_URL" >&2
    exit 1
  fi
  OLD_ITEM_COUNT="$(xmllint --xpath \
    "count(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'])" \
    "$WORKTREE_DIR/appcast.xml")"
  if (( OLD_ITEM_COUNT > 0 )); then
    xmllint --xpath \
      "/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item']" \
      "$WORKTREE_DIR/appcast.xml" > "$OLD_ITEMS"
  else
    : > "$OLD_ITEMS"
  fi
else
  : > "$OLD_ITEMS"
fi

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

TITLE_XML="$(printf '%s' "$RELEASE_TITLE" | xml_escape)"
PUB_DATE_XML="$(printf '%s' "$PUB_DATE" | xml_escape)"
ASSET_URL_XML="$(printf '%s' "$ASSET_URL" | xml_escape)"
SIGNATURE_XML="$(printf '%s' "$ED_SIGNATURE" | xml_escape)"
BUILD_VERSION_XML="$(printf '%s' "$BUILD_VERSION" | xml_escape)"
SHORT_VERSION_XML="$(printf '%s' "$SHORT_VERSION" | xml_escape)"

{
  cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ShakeBoard Updates</title>
    <link>https://thisradlife.github.io/shakeboard/appcast.xml</link>
    <description>ShakeBoard release updates</description>
    <language>en</language>
    <item>
      <title>${TITLE_XML}</title>
      <pubDate>${PUB_DATE_XML}</pubDate>
      <sparkle:version>${BUILD_VERSION_XML}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION_XML}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${ASSET_URL_XML}" length="${FILE_LENGTH}" type="application/octet-stream" sparkle:edSignature="${SIGNATURE_XML}" />
    </item>
EOF
  cat "$OLD_ITEMS"
  cat <<'EOF'
  </channel>
</rss>
EOF
} > "$WORKTREE_DIR/appcast.xml"

xmllint --noout "$WORKTREE_DIR/appcast.xml"
NEW_ITEM_COUNT="$(xmllint --xpath \
  "count(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item'])" \
  "$WORKTREE_DIR/appcast.xml")"
if (( NEW_ITEM_COUNT != OLD_ITEM_COUNT + 1 )); then
  echo "Appcast item-count check failed: expected $((OLD_ITEM_COUNT + 1)), found $NEW_ITEM_COUNT" >&2
  exit 1
fi
git -C "$WORKTREE_DIR" add -N appcast.xml
echo "Publish destination: $PUBLISH_REPO_URL (gh-pages)"
git -C "$WORKTREE_DIR" diff -- appcast.xml

if (( DRY_RUN )); then
  DRY_RUN_OUTPUT="${TMPDIR:-/tmp}/ShakeBoard-appcast-${VERSION}.xml"
  cp "$WORKTREE_DIR/appcast.xml" "$DRY_RUN_OUTPUT"
  echo "Dry run complete: wrote $DRY_RUN_OUTPUT (no commit or push)"
  exit 0
fi

if (( ! ASSUME_YES )); then
  printf 'Commit and push this appcast to gh-pages? [y/N] '
  read -r ANSWER
  if [[ ! "$ANSWER" =~ ^[Yy]$ ]]; then
    echo "Cancelled; nothing was committed or pushed"
    exit 0
  fi
fi

git -C "$WORKTREE_DIR" add appcast.xml
git -C "$WORKTREE_DIR" commit -s -m "Publish ShakeBoard $TAG appcast"
git -C "$WORKTREE_DIR" push "$PUBLISH_REPO_URL" HEAD:gh-pages
echo "Published $TAG to https://thisradlife.github.io/shakeboard/appcast.xml"
