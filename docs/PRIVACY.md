# Privacy

ShakeBoard is a local-only macOS app. It has no accounts, analytics, telemetry, advertising, or crash-reporting SDKs.

## Data stored on this Mac

ShakeBoard stores its working data under `~/Library/Application Support/ShakeBoard`:

- `shelf.json` contains plain file bookmarks for files placed on the shelf.
- `Shelf/` contains copies ShakeBoard owns, such as files received through the Share Extension.
- `Clips/` contains clipboard-history records and their local representations.
- `stacks.json` contains paste-stack names, order, and clip references.
- `mcp/audit.jsonl` is an owner-only (`0600`) MCP request log. It records time, verified client, tool, outcome, and
  counts, but never clipboard contents, search queries, or clip identifiers.

Preferences are stored in the standard macOS preferences domain for `com.thisradlife.shakeboard`, including shortcuts,
retention limits, ignored apps, and privacy settings.

## Clipboard capture

ShakeBoard polls the local pasteboard only while it is running. It skips:

- concealed, transient, auto-generated, and ShakeBoard-authored pasteboard types;
- copies made while Secure Input is active;
- copies from known password managers; and
- copies from apps added to the **Never save copies from** list.

You can pause clipboard history and configure count- and age-based retention in Settings. Clearing history removes
stored clips that are not still needed by a pin or paste stack. Shelf files and owned Share Extension copies are
managed separately.

## MCP bridge

AI access is off by default. When enabled, the bundled `shakeboard-mcp` helper communicates with the running app over a
local, owner-only Unix socket; it does not open a network port. Each verified client requires consent. Returned text
is filtered by best-effort redaction, and requests are audit-logged without content. Shelf file contents are never
served, and shelf names are excluded unless explicitly enabled.

## Network access

ShakeBoard makes no network requests today.

A future Sparkle update check is planned to fetch an HTTPS appcast from GitHub. It will be the app's only automatic
network request and automatic checks will require opt-in. Future backup or sync will also be opt-in and end-to-end
encrypted so the service cannot read stored content.

## Delete your data

Quit ShakeBoard, then remove:

- `~/Library/Application Support/ShakeBoard`
- `~/Library/Containers/com.thisradlife.shakeboard.share` (Share Extension data, including any interrupted handoffs)

Remove preferences with:

```bash
defaults delete com.thisradlife.shakeboard
```

You can also remove ShakeBoard from Login Items and revoke its Accessibility permission in System Settings. Empty Trash to
complete deletion of the files.
