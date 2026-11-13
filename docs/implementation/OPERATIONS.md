# Build, deploy and recover

## Local build

Requires macOS 26 (Tahoe) or later, Xcode 26 or Command Line Tools with Swift 6.2. Open `Package.swift` in Xcode or use:

```sh
swift test --triple "$(uname -m)-apple-macosx26.0"
./scripts/build-app.sh
open build/Nevermore.app
```

The build script uses the installed Apple Development identity. With several, it signs with the one whose name sorts first byte by byte (uppercase before lowercase, whatever the locale), so rebuilds keep the keychain access the designated requirement grants. Override `SIGN_IDENTITY` (a SHA-1 hash from `security find-identity -v -p codesigning` is always unambiguous) for another identity. `UNIVERSAL=1 CONFIGURATION=release ./scripts/build-app.sh` builds arm64 and x86_64 with explicit macOS 26 compiler targets. Use `swift test --triple "$(uname -m)-apple-macosx26.0"` to enforce the same API availability checks in tests. An explicit isolated demo is available with `open build/Nevermore.app --args --demo`. It uses `demo.invalid` and cannot send anything. File → Cancel Receiving Files cancels in-flight imports. Pending imports block Send across shared-draft windows. Long code has Expand/Collapse, exact Copy Code and a native reader with horizontal scrolling/optional wrapping. Copy Transcript includes full code from the loaded received messages even when collapsed. Settings includes text size/spacing and account preferences. File → New Message / Open Conversation provides a keyboard chooser; typing @ or # opens identity-aware completion. Wide windows can show a thread inspector; the same command opens a separate thread window when narrow.

## Dedicated OAuth registration

Create an independent public OAuth Client in the target Frappe site, without modifying Raven Mobile’s registration. Open Frappe Desk (`/desk`), search for OAuth Client, and create a registration with Token Endpoint Auth Method **None**, grant **Authorization Code** and response type **Code**. Configure the exact redirect URI `ch.goodvantage.Nevermore://oauth`, the server-supported `all openid` scopes and PKCE/S256. Never put a client secret into this app. Administrators must verify public-client PKCE support on each supported Frappe version. Enter the canonical HTTPS origin and this client ID in Add Account. Once the site field holds an acceptable origin, Add Account shows a link to `<origin>/desk/integrations/oauth-client`, the site's OAuth Client list, and one click opens it in the default browser. Frappe 16 routes `/desk/<module>/<doctype>` to that list. Frappe 15 redirects the address to `/app/integrations/oauth-client` and opens the Integrations workspace, where OAuth Client is one more click ([evidence](../RAVEN-RESEARCH.md#oauth-client-list-in-desk)). The page needs a Desk login that may read OAuth Clients, and Nevermore itself never requests it. The Client ID field starts with a built-in preset client ID. Frappe generates a client ID per registration, so the preset fits only the site it was registered on: replace it for any other site. Sign In Again keeps the account's own client ID. Login/SSO/MFA runs in the system browser. The identity returned by the server, not the browser’s assumed identity, names the account.

When retaining multiple callback URIs, enter them on **one line separated by a single space**, not separate lines. Frappe 16.53.0's [redirect validator](https://github.com/frappe/frappe/blob/v16.53.0/frappe/oauth.py#L24-L37) splits the field on a literal space and compares each URI exactly. For the transition from an earlier development build, list both callbacks, for example `ch.lkmc.Nevermore://oauth ch.goodvantage.Nevermore://oauth` in Redirect URIs, and use `ch.goodvantage.Nevermore://oauth` as Default Redirect URI. A newline-separated list produces `Mismatching redirect URI` before consent.

A custom external hostname and Frappe sitename are distinct. Nevermore uses the returned sitename for the Socket.IO namespace while keeping HTTP credentials bound to the original origin. Certificate errors require fixing the site or installing the organization's trust root through macOS; there is no TLS bypass.

## Real-server validation

Read-only starter probe:

```sh
RAVEN_ORIGIN=https://your-site.example RAVEN_ACCESS_TOKEN=… ./scripts/check-live-contracts.py
```

Supply credentials through your secure environment, not shell history or checked-in files. The probe logs only endpoint names and result status. Run on separately seeded Frappe 15.111+ and 16 sites. Record installed commits, reverse proxy settings and OAuth registration. Use two real users to verify private channels, DM/thread access, upload/download Range behavior, permission revocation, lost acknowledgements and web-client rendering. Socket delivery needs an authenticated real site; mocked HTTP tests cannot substitute for it.

## Local data and recovery

The sandbox container's Application Support/Nevermore directory holds account metadata and one UUID directory per account. Keychain entries hold tokens. Drafts and sends are durable SQLite data; do not manually delete account directories to solve a transient network failure. Outbox → Copy Text recovers a failed send. Retry retains its original payload/key and silent-send choice. Quit waits for local draft persistence and accepted-send bookkeeping; it does not wait for delivery to the server. Failed or unsupported drafts keep the app open for recovery. Old sends pause for explicit review. No silent seven-day expiry is used.

Clear Received History preserves drafts and outbox. Disable retained history for shared Macs. Removing an account explicitly discards its unsent work, removes credentials and private storage, and closes its views. OS backups/exported files cannot be recalled. There is no application-layer encryption claim; use FileVault/device policy where appropriate.

Before any future schema migration that cannot be reversed, keep an account-directory backup and validate recovery on a copy. Never restore another user's database under an existing account ID. Credentials should be reacquired by browser sign-in after recovery.

## Direct distribution and updates

Releases are built by `.forgejo/workflows/release.yml` on the forge's Mac: Developer ID signing with the Goodvantage team's certificate, hardened runtime, the sandbox, and notarized, stapled app and DMG. `CICD.md` lists the secrets it needs. From an up-to-date `main`:

```sh
scripts/release.sh 0.2.0 --push      # 0.2.0-beta.1 goes to the beta channel
```

The workflow tests the tagged commit, then publishes `Nevermore-<version>-macos-universal.dmg` and its `.sha256` on the forge release and on [apps.goodvantage.cloud](https://apps.goodvantage.cloud/#nevermore). The dependency notices ship inside the app. A version on the site is immutable: fix a bad release with a new version, never by rebuilding the same one.

The annotated tag's message becomes the release notes on both. Name the supported server revisions there. To write notes, replace the tag's message before pushing; `--cleanup=whitespace` keeps lines that start with `#`:

```sh
scripts/release.sh 0.2.0
git tag -a -f --cleanup=whitespace v0.2.0 -F notes.txt
git push origin HEAD && git push origin v0.2.0
```

To package locally instead, with a Developer ID identity in the keychain and a notarytool keychain profile:

```sh
SIGN_IDENTITY='Developer ID Application: …' NOTARY_PROFILE=nevermore-release \
./scripts/package-release.sh
```

## Update notices

Nevermore independently implements the documented apps-site advisory-check contract used by GoodDrive. No GoodDrive application source is copied. About ten seconds after launch, then every 24 hours while running, it reads `https://apps.goodvantage.cloud/nevermore/beta.json` for prereleases or `stable.json` otherwise. A stable release may supersede a beta on the beta feed. SemVer precedence ignores build metadata and compares numeric identifiers without integer overflow.

Checks use a separate ephemeral URLSession without cookies, credentials or cache, bounded to 256 KiB and 30 seconds overall. Redirects and authentication challenges are refused (normal system TLS trust validation is retained). Only schema 1 for `nevermore`, a newer eligible version and a valid `macos` artifact produce an offer. Browser downloads must be HTTPS on apps.goodvantage.cloud in that exact Nevermore version's directory; the website action uses a fixed URL. An unpublished channel (404) or missing macOS artifact means no offer. Other errors are reported on manual checks and logged quietly; automatic checks retry at the next interval.

The sidebar and menus retain a notice until that version is dismissed or installed. The app remembers a notification attempt per version before asking macOS for permission, preventing repeated prompts after denial or relaunch. Manual checks show a native review window instead of a system notification. Settings → General controls automatic checks (`checksForUpdatesAutomatically`, default true); manual checks work independently. Demos, native fixtures and performance runs do not initiate automatic checks. Tests inject isolated manifests and preferences, not production accounts.

**Download opens your browser; installation is manual.** The manifest is an HTTPS advisory, not a signed Sparkle appcast. Nevermore does not fetch or execute the installer or claim to verify its checksum in the browser. macOS signing, notarization and Gatekeeper remain the installer trust boundary. Sparkle stays dormant, including in builds with legacy feed/key fields; adding a self-installing updater would require a separate signed-update design and packaged-app validation.

No push provider is configured. Closing the last window leaves Nevermore running; Quit really exits. Running-app notifications have generic private bodies. Sleeping/quit Macs do not get guaranteed delivery. Native calls, AI administration, unverified archive/mute contracts and provider-side push are outside this initial implementation.

## Native interaction smoke check

After building the signed bundle, run:

```sh
build/Nevermore.app/Contents/MacOS/Nevermore --demo --self-check
```

This uses a disposable local demo store and exits after checking native text selection, marked text, shared windows, mention completion/Undo and modified Return, rich lists/code, the thread inspector, chooser, scheduled editing/cancellation, local account preferences and a 10,000-message synthetic input. It does not send server messages. Its single window-render timing sample is not a full performance benchmark or a VoiceOver certification.
