# Privacy

ShakeBoard is a local-first macOS app. It has no accounts, analytics, telemetry, advertising, or crash-reporting SDKs.

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

Update checks are ShakeBoard's only network access. Automatic checks are off by default. The next time Settings opens,
ShakeBoard asks once at the top of Settings > General whether to turn them on. Choosing **Not Now** keeps them off, and
the **Automatically check for updates** toggle remains available in the Updates section. ShakeBoard suppresses
Sparkle's separate permission window so an opt-in question cannot be missed behind another app. You can always run a
manual check from Settings > General.

An update check makes a standard HTTPS request to
`https://thisradlife.github.io/shakeboard/appcast.xml`. If an update is accepted, Sparkle downloads the signed DMG over
HTTPS from the ShakeBoard GitHub release. The DMG's EdDSA signature from the appcast is verified before the update is
installed.
System profiling is disabled: ShakeBoard does not send hardware, operating-system, language, or other profile fields.
Beyond the ordinary HTTP request metadata, the request includes only a User-Agent identifying ShakeBoard and its
version. There are no accounts, analytics identifiers, clipboard contents, file names, or other app data in the
request.

No other networking may be added without updating this policy. Any future backup or sync design remains separate and
would need to be opt-in and end-to-end encrypted so the service cannot read stored content.

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
