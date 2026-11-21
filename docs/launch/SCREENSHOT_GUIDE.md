# Safe launch screenshot guide

Launch images must show the real app with synthetic data. Never run a branch build against your normal ShakeBoard or pre-launch data directory. Never capture real clipboard history, shelf contents, settings, file paths, menu-bar items, Desktop icons, notifications, account names, customer details, email addresses, addresses, credentials, repository secrets, or real file names.

Final public images must come from the current ShakeBoard build. The capture-only seed and debug switches retain their implemented `PERCH_*` names, but isolated app data uses `SHAKEBOARD_DATA_DIR`.

## 1. Make isolated directories

Use a short path because the local MCP Unix socket has a path-length limit.

```sh
CAPTURE_DIR="$(mktemp -d /tmp/shakeboard-capture.XXXXXX)"
export PERCH_LAUNCH_IMAGES="$CAPTURE_DIR/fake-kiln-note.png:$CAPTURE_DIR/fake-product-card.png"
```

`SHAKEBOARD_DATA_DIR` isolates app data and preferences. `PERCH_LAUNCH_IMAGES` is a colon-separated list of synthetic image files for the launch seed. Create those files inside `CAPTURE_DIR`; never point it at personal images. Snapshots are written inside `SHAKEBOARD_DATA_DIR`.

The isolated build uses the `com.thisradlife.shakeboard.devdata` defaults suite. Pause live clipboard capture before every screenshot session so the seed cannot be mixed with the current clipboard:

```sh
defaults write com.thisradlife.shakeboard.devdata capturePaused -bool true
```

Build outside iCloud. Then launch the real app binary with only the capture state you need:

```sh
env SHAKEBOARD_DATA_DIR="$CAPTURE_DIR" \
  PERCH_LAUNCH_IMAGES="$PERCH_LAUNCH_IMAGES" \
  PERCH_DEBUG_SHOW="launch,lane,snapshot" \
  /tmp/shakeboard-build/Build/Products/Release/ShakeBoard.app/Contents/MacOS/ShakeBoard
```

Do not combine unrelated debug states. A smaller state is easier to inspect.

## 2. Seed only fake material

Use checked-in synthetic seed assets. Safe examples include `example.com` links, `555` phone numbers, invented product notes, sample JSON, and files created inside `CAPTURE_DIR`. Do not use a real customer, artist, gallery address, order, token, current clipboard item, or file copied from a personal directory.

Useful starting states are:

```sh
PERCH_DEBUG_SHOW="launch,snapshot"
PERCH_DEBUG_SHOW="launch,lane,snapshot"
PERCH_DEBUG_SHOW="launch,board,snapshot"
PERCH_DEBUG_SHOW="launch,picks,snapshot"
PERCH_DEBUG_SHOW="launch,edit,snapshot"
PERCH_DEBUG_SHOW="launch,query=kiln,snapshot"
PERCH_DEBUG_SHOW="pinboards,snapshot"
PERCH_DEBUG_SHOW="stacks,strip,snapshot"
PERCH_DEBUG_SHOW="history,picks,snapshot"
PERCH_DEBUG_SHOW="settings,snapshot"
PERCH_DEBUG_SHOW="settings,privacy,snapshot"
PERCH_DEBUG_SHOW="consent,snapshot"
PERCH_DEBUG_SHOW="edit,history,snapshot"
PERCH_DEBUG_SHOW="preview"
```

For OCR, point at a purpose-made fake image:

```sh
env SHAKEBOARD_DATA_DIR="$CAPTURE_DIR" \
  PERCH_LAUNCH_IMAGES="$PERCH_LAUNCH_IMAGES" \
  PERCH_DEBUG_SHOW="ocr" \
  PERCH_OCR_SEED="$CAPTURE_DIR/fake-kiln-note.png" \
  /tmp/shakeboard-build/Build/Products/Release/ShakeBoard.app/Contents/MacOS/ShakeBoard
```

## 3. Capture clean masters

Hide notifications, personal menu-bar items, mounted volumes, recent files, Desktop icons, and the account name before capture. Use a clean macOS desktop. Do not add a fake cursor unless the image explains a click target.

Preserve a lossless Retina PNG master. Export web derivatives from that master. Cropping, masking the desktop, and adding a shadow are allowed. Redrawing or changing app UI is not. If the state is wrong, reproduce it in the app and capture it again.

## 4. Inspect before committing

Open every image at 100 percent. Search visible text for real names, email addresses, phone numbers, `/Users/` paths, tokens, API keys, order numbers, real repository names, and unrelated window titles. Confirm that visible product strings say ShakeBoard and that no future feature appears as shipped. Built-in signed updates shipped in 1.0 and are opt-in. Homebrew and encrypted backup or sync must be labeled **Coming**.

Quit the capture build only after approved masters are copied out. Remove the temporary directory only after resolving and checking its exact path. Do not add a broad automated cleanup command to a shared script.
