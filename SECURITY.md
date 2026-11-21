# Security Policy

## Supported versions

Only the latest release receives security updates.

## Reporting a vulnerability

Use GitHub private vulnerability reporting: open the repository's **Security** tab and choose
**Report a vulnerability**. Never report a suspected vulnerability in a public issue.

Never include real clipboard contents, tokens, or personal files in a report -- use synthetic data.

The maintainers aim to acknowledge reports within 7 days. For high- or critical-severity issues, the goal is to
provide a fix or a documented remediation plan within 30 days. Timelines may vary with complexity, but the
maintainers will communicate status and coordinate disclosure with the reporter. Please do not publish details until
a fix is available or a disclosure date has been agreed.

## Scope

Security reports are welcome for:

- The ShakeBoard macOS app, including local storage and clipboard handling.
- The `shakeboard://` Share Extension handoff. The URL scheme is world-invocable, so its input is untrusted;
  `validatedHandoffDir` and `ingestHandoff` constrain accepted directories and files.
- The MCP bridge: the embedded `shakeboard-mcp` helper, its owner-only local Unix socket, client consent, output redaction,
  and content-free audit log.
- The Sparkle updater and appcast, including update-signature validation and distribution integrity.
- Compromise or misuse of the Sparkle EdDSA signing key, release-signing credentials, or appcast publishing path.
- The planned opt-in encrypted backup and sync vault.

Reports about weakening handoff validation, bypassing MCP consent or redaction, exposing clipboard data, replacing a
trusted local peer, or compromising updater, appcast, signing-key, or future vault integrity are especially valuable.
